#!/bin/bash
# Creates a self-signed code signing identity in a dedicated keychain, so rebuilt app bundles keep
# the same designated requirement and macOS privacy grants (Screen Recording, Accessibility) survive rebuilds.
set -eu
KC="$HOME/Library/Keychains/padlink-signing.keychain-db"
# Password of this throwaway keychain only; it holds nothing but the local signing identity.
PW="${PADLINK_KEYCHAIN_PASSWORD:-padlink-local}"
NAME="PadLink Local Signing"
if [ -f "$KC" ] && security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
  echo "identity exists"; exit 0
fi
TMP=$(mktemp -d /tmp/padlink-sign.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 7300 -config "$TMP/cfg" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:$PW
[ -f "$KC" ] || security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
security find-identity -p codesigning "$KC"
