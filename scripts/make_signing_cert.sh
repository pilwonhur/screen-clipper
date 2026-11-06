#!/bin/bash
# One-time setup: creates a local code-signing certificate "Screen Clipper Dev" in your login
# keychain. build_app.sh then signs with it, so macOS keeps Screen Recording / Accessibility
# permissions across rebuilds. The certificate is only used to sign this app.
# To remove later: Keychain Access → login → My Certificates → delete "Screen Clipper Dev".
set -euo pipefail

if security find-identity -p codesigning 2>/dev/null | grep -q "Screen Clipper Dev"; then
  echo "Certificate already exists."; exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Screen Clipper Dev
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cert.cnf" 2>/dev/null
# macOS's importer only reads the older PKCS12 format (SHA1 MAC, 3DES).
P12_ARGS=(-export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/sc.p12" -passout pass:screenclipper -name "Screen Clipper Dev")
openssl pkcs12 "${P12_ARGS[@]}" -legacy 2>/dev/null \
  || openssl pkcs12 "${P12_ARGS[@]}" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null \
  || /usr/bin/openssl pkcs12 "${P12_ARGS[@]}"
security import "$TMP/sc.p12" -k ~/Library/Keychains/login.keychain-db -P screenclipper -T /usr/bin/codesign
echo "Created certificate:"
security find-identity -p codesigning | grep "Screen Clipper Dev"
