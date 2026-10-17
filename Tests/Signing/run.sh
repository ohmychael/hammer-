#!/bin/bash
# Tests signing.sh (the stable signing certificate) with stand-ins for macOS's
# security and codesign tools; the certificate is made with the real openssl.
# Runs on Linux or a Mac in a few seconds: Tests/Signing/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failed=0
check() { if eval "$1"; then echo "  ok   $2"; else echo "  FAIL $2"; failed=$((failed + 1)); fi; }

export FAKE_STATE="$WORK/state" HAMMER_SIGN_DIR="$WORK/home/Hammer/signing"
export HAMMER_SECURITY="$HERE/fake_security.py" HAMMER_CODESIGN="$HERE/fake_codesign.py"
export HAMMER_OPENSSL="$(command -v openssl)"
mkdir -p "$FAKE_STATE" "$WORK/Hammer.app"
LOGIN="$WORK/home/Library/Keychains/login.keychain-db"
OTHER="$WORK/home/Library/Keychains/My Work Certs.keychain-db"     # a path with spaces
printf '%s\n%s\n' "$LOGIN" "$OTHER" > "$FAKE_STATE/search-list"
KC="$HAMMER_SIGN_DIR/hammer-signing.keychain-db"
# Like build.sh: strict mode, so a failing command would stop the "build".
sign() { ( set -euo pipefail; source "$REPO/signing.sh"; sign_app "$WORK/Hammer.app"; echo "build continued" ) 2>&1; }

echo "[first build]"
out="$(sign)"
check '[[ "$out" == "Signed with Hammer Local Signing"* ]]' "signed with the certificate: $out"
check '[ "$(cat "$WORK/Hammer.app/signature")" = certificate ]' "the app carries the certificate signature"
check '[ -f "$FAKE_STATE/signed-while-listed" ]' "codesign could find it (listed while signing)"
check '[[ "$out" == *"build continued" ]]' "the build carries on"
check '[ -f "$KC" ] && [ -s "$HAMMER_SIGN_DIR/password" ]' "keychain and password made"
check '[ "$(stat -c %a "$HAMMER_SIGN_DIR" 2>/dev/null || stat -f %Lp "$HAMMER_SIGN_DIR")" = 700 ]' "folder only you can open"
check '[ "$(stat -c %a "$HAMMER_SIGN_DIR/password" 2>/dev/null || stat -f %Lp "$HAMMER_SIGN_DIR/password")" = 600 ]' "password only you can read"
check '[ "$(cat "$FAKE_STATE/search-list")" = "$(printf "%s\n%s" "$LOGIN" "$OTHER")" ]' "your keychain search list is exactly as before"
# The certificate: code signing only, not a CA, made for 20 years.
python3 - "$KC" "$WORK/id.p12" <<'PY'
import json, sys
kc = json.load(open(sys.argv[1]))
open(sys.argv[2], "wb").write(bytes.fromhex(kc["p12"]))
open(sys.argv[2] + ".pass", "w").write(kc["p12pass"])
PY
CERT="$(openssl pkcs12 -in "$WORK/id.p12" -passin "file:$WORK/id.p12.pass" -nokeys -legacy 2>/dev/null \
        || openssl pkcs12 -in "$WORK/id.p12" -passin "file:$WORK/id.p12.pass" -nokeys 2>/dev/null)"
TEXT="$(printf '%s' "$CERT" | openssl x509 -noout -text 2>/dev/null)"
check 'grep -q "Subject: CN *= *Hammer Local Signing" <<<"$TEXT"' "certificate named Hammer Local Signing"
check 'grep -q "Code Signing" <<<"$TEXT" && grep -q "CA:FALSE" <<<"$TEXT"' "for code signing only, not a CA"
check 'grep -A1 "Key Usage: critical" <<<"$TEXT" | grep -q "Digital Signature"' "digital signature key usage"
check '[ -z "$(ls -A "$HAMMER_SIGN_DIR" | grep -v -e hammer-signing.keychain-db -e password)" ]' "no key files left lying around"

echo "[next builds]"
before="$(grep -c create-keychain "$FAKE_STATE/security-log")"
out="$(sign)"; out2="$(sign)"
check '[[ "$out2" == "Signed with Hammer Local Signing"* ]]' "still signed with the certificate"
check '[ "$(grep -c create-keychain "$FAKE_STATE/security-log")" = "$before" ]' "the same certificate is reused, not remade"
check '[ "$(wc -l < "$FAKE_STATE/search-list")" = 2 ]' "search list still untouched"

echo "[the keychain gets back on the search list somehow]"
printf '%s\n%s\n%s\n' "$LOGIN" "$KC" "$OTHER" > "$FAKE_STATE/search-list"
sign >/dev/null
check '[ "$(cat "$FAKE_STATE/search-list")" = "$(printf "%s\n%s" "$LOGIN" "$OTHER")" ]' "taken off again, order kept"

echo "[codesign refuses the certificate]"
out="$(FAKE_REFUSE=1 sign)"
check '[[ "$out" == "Signed ad hoc"* ]] && [ "$(cat "$WORK/Hammer.app/signature")" = adhoc ]' "falls back to ad hoc"
check '[[ "$out" == *"build continued" ]]' "and the build carries on"
check '[ "$(cat "$FAKE_STATE/search-list")" = "$(printf "%s\n%s" "$LOGIN" "$OTHER")" ]' "search list put back"

echo "[the signature doesn't verify]"
out="$(FAKE_VERIFY_FAIL=1 sign)"
check '[[ "$out" == "Signed ad hoc"* ]] && [[ "$out" == *"build continued" ]]' "falls back to ad hoc, build carries on"
check '[ "$(cat "$FAKE_STATE/search-list")" = "$(printf "%s\n%s" "$LOGIN" "$OTHER")" ]' "search list put back"

echo "[the keychain no longer opens (e.g. restored from a backup)]"
printf 'not-the-password' > "$HAMMER_SIGN_DIR/password"
out="$(sign)"
check '[[ "$out" == "Signed with Hammer Local Signing"* ]]' "made again and signed with the certificate"
check '[ "$(cat "$FAKE_STATE/search-list")" = "$(printf "%s\n%s" "$LOGIN" "$OTHER")" ]' "search list untouched"

echo "[the search list can't be read]"
mv "$FAKE_STATE/search-list" "$FAKE_STATE/search-list.saved"
out="$(sign)"
check '[[ "$out" == "Signed ad hoc"* ]] && [[ "$out" == *"build continued" ]]' "doesn't touch it, signs ad hoc"
mv "$FAKE_STATE/search-list.saved" "$FAKE_STATE/search-list"

echo "[making the certificate fails]"
rm -rf "$HAMMER_SIGN_DIR"
out="$(HAMMER_OPENSSL=/bin/false sign)"
check '[[ "$out" == "Signed ad hoc"* ]] && [[ "$out" == *"build continued" ]]' "falls back to ad hoc"
check '[ ! -e "$KC" ] && [ ! -e "$HAMMER_SIGN_DIR/password" ]' "and leaves nothing half-made"
check '[ "$(cat "$FAKE_STATE/search-list")" = "$(printf "%s\n%s" "$LOGIN" "$OTHER")" ]' "search list untouched"

echo "[the password file goes missing]"
sign >/dev/null
rm -f "$HAMMER_SIGN_DIR/password"
out="$(sign)"
check '[[ "$out" == "Signed with Hammer Local Signing"* ]] && [ -s "$HAMMER_SIGN_DIR/password" ]' "remade, signed with a new certificate"

echo "[build.sh uses it]"
check 'grep -q "^source \"\$REPO/signing.sh\"" "$REPO/build.sh" && grep -q "^sign_app \"\$STAGE\"" "$REPO/build.sh"' "build.sh signs through signing.sh"
check '! grep -q "codesign --force --sign -" "$REPO/build.sh"' "and no longer signs ad hoc directly"

[ "$failed" = 0 ] && echo "All signing tests passed." || echo "$failed signing tests FAILED."
exit $failed
