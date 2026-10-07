#!/usr/bin/env bash
# One time: store the four signing secrets the release workflow needs that can only come
# from the maintainer's Mac. Run it yourself in a terminal (macOS may ask for the login
# keychain password, once per item):
#
#   bash Scripts/setup-release-secrets.sh [path/to/AuthKey_<ID>.p8]
#
#   AC_API_KEY_P8               the App Store Connect API key, base64
#   DEVELOPER_ID_CERT_P12       ONLY the "Developer ID Application" identity, with its
#                               intermediate, exported with the legacy PBE algorithms
#                               macOS `security import` accepts on the runner
#   DEVELOPER_ID_CERT_PASSWORD  a fresh random password for that .p12
#   SPARKLE_ED_PRIVATE_KEY      the EdDSA key Sparkle's generate_keys keeps in the keychain
#
# AC_API_KEY_ID, AC_API_ISSUER_ID and KEYCHAIN_PASSWORD are plain values and are set
# separately with `gh secret set`. Nothing is written outside a temporary folder, which is
# shredded on exit, and the .p12 is test imported into a throwaway keychain first.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${REPO:-joymadhu49/snapline}"
P8="${1:-$HOME/Downloads/AuthKey_U3JMVH4963.p8}"
TEAM="CJZMYQN8V6"
OPENSSL=/usr/bin/openssl   # LibreSSL: writes PKCS#12 that `security import` can read

WORK="$(mktemp -d)"
ORIG_KEYCHAINS="$(security list-keychains -d user | sed 's/[":]//g' | xargs)"
cleanup() {
    security list-keychains -d user -s $ORIG_KEYCHAINS 2>/dev/null || true
    security delete-keychain "$WORK/test.keychain-db" 2>/dev/null || true
    find "$WORK" -type f -exec rm -P {} + 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

# 1. App Store Connect API key. `gh secret set` happily stores an empty value, so check first.
[[ -s "$P8" ]] || die "no API key at $P8 (pass the AuthKey_<ID>.p8 path as the first argument)"
echo "==> AC_API_KEY_P8 from $(basename "$P8")"
base64 -i "$P8" | tr -d '\n' > "$WORK/p8.b64"
[[ -s "$WORK/p8.b64" ]] || die "base64 of $P8 came out empty"
gh secret set AC_API_KEY_P8 -R "$REPO" < "$WORK/p8.b64"

# 2. The Developer ID identity, alone. `security export` dumps every identity in the
#    keychain, so split the dump and keep just the one certificate and its matching key.
echo "==> Exporting the Developer ID Application identity (team $TEAM)"
PASS="$($OPENSSL rand -hex 24)"
security export -k "$HOME/Library/Keychains/login.keychain-db" -t identities -f pkcs12 \
    -P "$PASS" -o "$WORK/all.p12"
$OPENSSL pkcs12 -in "$WORK/all.p12" -passin "pass:$PASS" -nodes -out "$WORK/all.pem" 2>/dev/null
awk -v dir="$WORK" '
    /-----BEGIN CERTIFICATE-----/ { n++; f = sprintf("%s/cert-%02d.pem", dir, n) }
    /-----BEGIN .*PRIVATE KEY-----/ { k++; f = sprintf("%s/key-%02d.pem", dir, k) }
    f { print > f }
    /-----END / { close(f); f = "" }
' "$WORK/all.pem"

CERT=""
for c in "$WORK"/cert-*.pem; do
    if $OPENSSL x509 -in "$c" -noout -subject 2>/dev/null | grep -q "Developer ID Application.*$TEAM"; then
        CERT="$c"; break
    fi
done
[[ -n "$CERT" ]] || die "no 'Developer ID Application' certificate for team $TEAM in the login keychain"
WANT="$($OPENSSL x509 -in "$CERT" -pubkey -noout)"
KEY=""
for k in "$WORK"/key-*.pem; do
    [[ "$($OPENSSL pkey -in "$k" -pubout 2>/dev/null)" == "$WANT" ]] && { KEY="$k"; break; }
done
[[ -n "$KEY" ]] || die "found the certificate but not its private key"

security find-certificate -c "Developer ID Certification Authority" -p > "$WORK/intermediate.pem"
$OPENSSL pkcs12 -export -in "$CERT" -inkey "$KEY" -certfile "$WORK/intermediate.pem" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$PASS" -out "$WORK/devid.p12"

# Import it the way the workflow does, into a throwaway keychain, before uploading anything.
echo "==> Test importing the .p12"
TEST="$WORK/test.keychain-db"
security create-keychain -p test "$TEST"
security unlock-keychain -p test "$TEST"
security import "$WORK/devid.p12" -k "$TEST" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k test "$TEST" >/dev/null
COUNT="$(security find-identity -v -p codesigning "$TEST" | grep -c 'Developer ID Application' || true)"
[[ "$COUNT" == "1" ]] || die "expected exactly one identity in the test import, found $COUNT"

base64 -i "$WORK/devid.p12" | tr -d '\n' > "$WORK/p12.b64"
gh secret set DEVELOPER_ID_CERT_P12 -R "$REPO" < "$WORK/p12.b64"
printf '%s' "$PASS" | gh secret set DEVELOPER_ID_CERT_PASSWORD -R "$REPO"

# 3. Sparkle's EdDSA key. The tool comes with the Sparkle package the build resolved.
GENERATE_KEYS="$(find build/SourcePackages/artifacts -path '*/bin/generate_keys' 2>/dev/null | head -1)"
[[ -n "$GENERATE_KEYS" ]] || die "Sparkle's generate_keys not found. Run: bash Scripts/build.sh"
echo "==> SPARKLE_ED_PRIVATE_KEY"
"$GENERATE_KEYS" -x "$WORK/sparkle.key" >/dev/null
[[ -s "$WORK/sparkle.key" ]] || die "generate_keys exported nothing"
gh secret set SPARKLE_ED_PRIVATE_KEY -R "$REPO" < "$WORK/sparkle.key"

echo
gh secret list -R "$REPO"
echo
echo "Done. The next version bump in project.yml, pushed to main, releases itself."
