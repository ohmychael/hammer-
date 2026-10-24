# signing.sh — used by build.sh. Signs Hammer.app with the same local certificate
# on every build, so macOS remembers what you've allowed (Bluetooth, local network,
# notifications) across updates.
#
# Why: an "ad hoc" signature is different for every build, so macOS treats each
# update as a new app and asks again ("Hammer would like to use Bluetooth"). A
# certificate that stays the same lets macOS recognize Hammer.
#
# The certificate is made once, on your Mac, the first time this runs. It lives in
# its own keychain at ~/Hammer/signing, not in your login keychain, with a random
# password kept next to it (readable only by you). It can only sign code, and
# nothing on your Mac trusts it for anything else. What it does allow: anything
# running as you could sign a program as "Hammer" and get Hammer's permissions
# (Bluetooth, local network). That's the same trust any app you run already has.
#
# macOS's codesign only finds a certificate whose keychain is in your keychain
# list, so the keychain is added to the list just for the moment of signing and
# taken off again right after, so no app ever asks you for its password. If the
# build is stopped part-way (a logout), build.sh takes it off then (signing_cleanup),
# and update.sh checks again on its next run. Each step has a time limit.
#
# If any step fails, Hammer is signed ad hoc as before, so a build never fails here,
# and the update log says which signature was used.
# To remove it all: rm -rf ~/Hammer/signing

SIGN_DIR="${HAMMER_SIGN_DIR:-$HOME/Hammer/signing}"
SIGN_NAME="Hammer Local Signing"
SECURITY="${HAMMER_SECURITY:-/usr/bin/security}"     # tests swap in stand-ins
OPENSSL="${HAMMER_OPENSSL:-/usr/bin/openssl}"        # macOS's LibreSSL
CODESIGN="${HAMMER_CODESIGN:-/usr/bin/codesign}"
SIGN_LIMIT="${HAMMER_SIGN_LIMIT:-120}"               # seconds per step, so a hang can't stop updates

# Runs a command, stopping it after SIGN_LIMIT seconds.
signing_limit() { perl -e 'alarm shift; exec @ARGV or die "$ARGV[0]: $!\n"' "$SIGN_LIMIT" "$@"; }

# The keychain while it's on your search list (for signing_cleanup).
SIGNING_LISTED=""

# build.sh calls this however it ends (even when stopped part-way, e.g. by a logout),
# so the signing keychain never stays on your search list.
signing_cleanup() {
  [ -n "$SIGNING_LISTED" ] || return 0
  signing_unlist "$SIGNING_LISTED" || true
  SIGNING_LISTED=""
}

# Your keychain search list, one path per line, without our keychain. Fails if the
# list can't be read, so it's never rewritten from a bad read.
signing_others() {
  local ours="$1" out line
  out="$("$SECURITY" list-keychains -d user 2>/dev/null)" || return 1
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"          # trim leading spaces
    line="${line#\"}"; line="${line%\"}"             # and the quotes around the path
    [ -n "$line" ] && [ "$line" != "$ours" ] && printf '%s\n' "$line"
  done <<< "$out"
  return 0
}

signing_listed() {
  local out
  out="$("$SECURITY" list-keychains -d user 2>/dev/null)" || return 1
  grep -qF "\"$1\"" <<< "$out"
}

# Takes our keychain off your search list. Only ever removes that one entry, and
# only if everything else is still there afterwards.
signing_unlist() {
  local ours="$1" others=() line
  signing_listed "$ours" || return 0
  while IFS= read -r line; do others+=("$line"); done < <(signing_others "$ours" || echo "")
  [ "${#others[@]}" -gt 0 ] && [ -n "${others[0]}" ] || return 0      # never leave the list empty
  "$SECURITY" list-keychains -d user -s "${others[@]}" >/dev/null 2>&1
}

# Adds our keychain to the end of your search list (for codesign).
signing_list() {
  local ours="$1" others=() line
  signing_listed "$ours" && return 0
  while IFS= read -r line; do others+=("$line"); done < <(signing_others "$ours" || echo "")
  [ "${#others[@]}" -gt 0 ] && [ -n "${others[0]}" ] || return 1      # couldn't read the list: don't touch it
  "$SECURITY" list-keychains -d user -s "${others[@]}" "$ours" >/dev/null 2>&1
}

signing_forget() {
  local kc="$1"
  signing_unlist "$kc"
  "$SECURITY" delete-keychain "$kc" >/dev/null 2>&1
  rm -f "$kc" "$SIGN_DIR/password"
}

# Makes the certificate and its keychain. Fails (returns 1) if anything doesn't work.
signing_make() {
  local kc="$1" pwfile="$SIGN_DIR/password" pw tmp ok
  signing_forget "$kc"
  # 16 random bytes as 32 hex digits. (Not `tr </dev/urandom | head`: where SIGPIPE
  # is ignored, as under some CI runners, that tr never stops.)
  pw="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  [ "${#pw}" = 32 ] || return 1
  ( umask 077; printf '%s' "$pw" > "$pwfile" ) || return 1
  tmp="$(mktemp -d)" || return 1
  cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SIGN_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
  # The .p12 uses the older encryption that macOS's `security import` reads.
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$tmp/cert.cnf" \
      -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 \
    && HAMMER_P12_PASS="$pw" "$OPENSSL" pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
      -name "$SIGN_NAME" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
      -passout env:HAMMER_P12_PASS -out "$tmp/identity.p12" >/dev/null 2>&1 \
    && "$SECURITY" create-keychain -p "$pw" "$kc" >/dev/null 2>&1 \
    && { signing_unlist "$kc"; true; } \
    && "$SECURITY" set-keychain-settings "$kc" >/dev/null 2>&1 \
    && "$SECURITY" unlock-keychain -p "$pw" "$kc" >/dev/null 2>&1 \
    && signing_limit "$SECURITY" import "$tmp/identity.p12" -k "$kc" -P "$pw" -T "$CODESIGN" >/dev/null 2>&1 \
    && signing_limit "$SECURITY" set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$kc" >/dev/null 2>&1
  ok=$?
  rm -rf "$tmp"                                       # the private key only stays in the keychain
  if [ "$ok" != 0 ]; then
    signing_forget "$kc"
    return 1
  fi
}

# Makes the keychain if needed (or remakes it if it no longer opens), unlocks it,
# and prints its path.
signing_keychain() {
  local kc="$SIGN_DIR/hammer-signing.keychain-db" pwfile="$SIGN_DIR/password" made=false
  mkdir -p "$SIGN_DIR" && chmod 700 "$SIGN_DIR" || return 1
  if [ ! -f "$kc" ] || [ ! -s "$pwfile" ]; then
    signing_make "$kc" || return 1
    made=true
  fi
  signing_unlist "$kc"                                # in case an earlier build stopped mid-way
  if ! "$SECURITY" unlock-keychain -p "$(cat "$pwfile")" "$kc" >/dev/null 2>&1; then
    $made && return 1
    signing_make "$kc" || return 1                    # broken (e.g. restored from a backup): start over
    "$SECURITY" unlock-keychain -p "$(cat "$pwfile")" "$kc" >/dev/null 2>&1 || return 1
  fi
  printf '%s\n' "$kc"
}

# sign_app <path to .app>. build.sh runs with `set -euo pipefail`, so everything
# that may fail here sits in an `if` condition or ends in `|| true`.
sign_app() {
  local app="$1" kc signed=false
  SIGNING_LISTED="$SIGN_DIR/hammer-signing.keychain-db"     # macOS lists it as soon as it's made
  if kc="$(signing_keychain)" && signing_list "$kc"; then
    if signing_limit "$CODESIGN" --force --timestamp=none --sign "$SIGN_NAME" --keychain "$kc" "$app" >/dev/null 2>&1 \
       && signing_limit "$CODESIGN" --verify "$app" >/dev/null 2>&1; then
      signed=true
    fi
  fi
  signing_cleanup
  if $signed; then
    echo "Signed with $SIGN_NAME, so permissions carry over between updates."
  else
    signing_limit "$CODESIGN" --force --sign - "$app" >/dev/null 2>&1 || true
    echo "Signed ad hoc (macOS may ask for permissions again after this update)."
  fi
}
