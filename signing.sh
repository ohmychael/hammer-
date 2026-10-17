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
# password kept next to it (readable only by you). That password only protects this
# signing key, which is why it's fine to keep beside it and to hand to `security`.
# The keychain is kept out of the list other apps search, so nothing ever asks you
# for its password. The certificate can only sign code; nothing trusts it for
# anything else.
#
# If any step fails, Hammer is signed ad hoc as before, so a build never fails here.
# To remove it all: rm -rf ~/Hammer/signing

SIGN_DIR="${HAMMER_SIGN_DIR:-$HOME/Hammer/signing}"
SIGN_NAME="Hammer Local Signing"
SECURITY="${HAMMER_SECURITY:-/usr/bin/security}"     # tests swap in stand-ins
OPENSSL="${HAMMER_OPENSSL:-/usr/bin/openssl}"        # macOS's LibreSSL
CODESIGN="${HAMMER_CODESIGN:-/usr/bin/codesign}"

# Takes our keychain back out of your keychain search list (security create-keychain
# adds it). Only ever removes that one entry, and only rewrites the list if the
# result still has everything else in it.
signing_unlist() {
  local ours="$1" line others=() found=false
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"          # trim leading spaces
    line="${line#\"}"; line="${line%\"}"             # and the quotes around the path
    [ -z "$line" ] && continue
    if [ "$line" = "$ours" ]; then found=true; else others+=("$line"); fi
  done < <("$SECURITY" list-keychains -d user 2>/dev/null)
  $found || return 0
  [ "${#others[@]}" -gt 0 ] || return 0                # never leave the list empty
  "$SECURITY" list-keychains -d user -s "${others[@]}" >/dev/null 2>&1
}

# Makes the certificate and its keychain if they don't exist yet, unlocks it, and
# prints the keychain's path. Fails (returns 1) if anything doesn't work.
signing_keychain() {
  local kc="$SIGN_DIR/hammer-signing.keychain-db" pwfile="$SIGN_DIR/password" pw tmp ok
  mkdir -p "$SIGN_DIR" && chmod 700 "$SIGN_DIR" || return 1
  if [ ! -f "$kc" ] || [ ! -s "$pwfile" ]; then
    rm -f "$kc"
    pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
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
    "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$tmp/cert.cnf" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 \
      && HAMMER_P12_PASS="$pw" "$OPENSSL" pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -name "$SIGN_NAME" -passout env:HAMMER_P12_PASS -out "$tmp/identity.p12" >/dev/null 2>&1 \
      && "$SECURITY" create-keychain -p "$pw" "$kc" >/dev/null 2>&1 \
      && { signing_unlist "$kc"; true; } \
      && "$SECURITY" set-keychain-settings "$kc" >/dev/null 2>&1 \
      && "$SECURITY" unlock-keychain -p "$pw" "$kc" >/dev/null 2>&1 \
      && "$SECURITY" import "$tmp/identity.p12" -k "$kc" -P "$pw" -T "$CODESIGN" >/dev/null 2>&1 \
      && "$SECURITY" set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$kc" >/dev/null 2>&1
    ok=$?
    rm -rf "$tmp"                                     # the private key only stays in the keychain
    if [ "$ok" != 0 ]; then
      signing_unlist "$kc"
      rm -f "$kc" "$pwfile"
      return 1
    fi
  fi
  signing_unlist "$kc"
  "$SECURITY" unlock-keychain -p "$(cat "$pwfile")" "$kc" >/dev/null 2>&1 || return 1
  printf '%s\n' "$kc"
}

# sign_app <path to .app>
sign_app() {
  local app="$1" kc
  if kc="$(signing_keychain)" \
     && "$CODESIGN" --force --sign "$SIGN_NAME" --keychain "$kc" "$app" >/dev/null 2>&1 \
     && "$CODESIGN" --verify "$app" >/dev/null 2>&1; then
    echo "Signed with $SIGN_NAME, so permissions carry over between updates."
  else
    "$CODESIGN" --force --sign - "$app" >/dev/null 2>&1 || true
    echo "Signed ad hoc (macOS may ask for permissions again after this update)."
  fi
}
