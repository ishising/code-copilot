#!/bin/bash
# Create a stable, self-signed code-signing identity for local builds.
#
# Why this exists: an ad-hoc signature (`codesign --sign -`) has no identity,
# so macOS TCC keys the Screen Recording and Accessibility grants to the
# binary's CDHash. That hash changes every time the code does, which silently
# invalidates the grant — the app still appears ticked in System Settings and
# is nonetheless treated as a different application on every rebuild.
#
# A self-signed certificate gives the bundle one identity that survives
# rebuilds, so the permissions are granted once and stay granted.
#
# Entirely local and reversible: delete "Code Copilot Local" in Keychain
# Access to undo it. Nothing is published, and no CA is involved.
set -euo pipefail

NAME="Code Copilot Local"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "identity already exists: $NAME"
  exit 0
fi

cat > "$TMP/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage         = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null

#: OpenSSL 3 defaults to a PKCS12 MAC that macOS's Security framework
# cannot verify, which fails the import with a misleading "wrong password?".
# A real password, not an empty one: macOS's importer rejects an empty-password
# PKCS12 with a misleading "MAC verification failed (wrong password?)".
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -name "$NAME" -passout pass:codecopilot 2>/dev/null

# -A lets codesign use the key without a confirmation dialog on every build.
security import "$TMP/identity.p12" -k ~/Library/Keychains/login.keychain-db \
  -P codecopilot -T /usr/bin/codesign -A >/dev/null

echo "created identity: $NAME"
echo "rebuild with ./bundle.sh, then grant permissions once more — they will stick."
