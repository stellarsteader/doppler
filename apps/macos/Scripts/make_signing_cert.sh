#!/usr/bin/env bash
# Creates a self-signed code-signing identity "Doppler Local" in your login keychain.
# build.sh signs with it, so the app keeps the same identity across rebuilds and macOS stops
# forgetting the Accessibility / Microphone permissions. Run once: ./Scripts/make_signing_cert.sh
set -euo pipefail

NAME="${SIGN_IDENTITY:-Doppler Local}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS="$(openssl rand -hex 16)"  # only protects the temporary .p12 below

# /usr/bin/openssl (LibreSSL) writes a .p12 the keychain can import; OpenSSL 3+ needs -legacy.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASS"

# -T lets codesign use the key without a keychain prompt on every build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\". Rebuild with ./build.sh --install, then grant Accessibility one last time."
