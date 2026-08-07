#!/bin/bash
# Creates a persistent self-signed code-signing certificate named "Whispr Dev".
# Signing every build with the same identity means macOS Keychain and
# Accessibility (TCC) grants survive rebuilds. With ad-hoc signing you get
# re-prompted on every binary change.
set -e

NAME="Whispr Dev"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "Certificate '$NAME' already exists:"
    security find-identity -v -p codesigning | grep "$NAME"
    exit 0
fi

echo "Creating self-signed certificate '$NAME'..."
openssl req -x509 -newkey rsa:2048 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=$NAME" \
    -addext "extendedKeyUsage=codeSigning" 2>/dev/null

security import "$TMP/key.pem"  -k login.keychain -T /usr/bin/codesign -T /usr/bin/security
security import "$TMP/cert.pem" -k login.keychain

echo ""
echo "Done. '$NAME' is now available for codesigning."
echo ""
echo "If 'make app' reports the identity is missing or errSecInternalComponent,"
echo "open Keychain Access, locate '$NAME' under login > My Certificates,"
echo "then Get Info > Trust > Code Signing > Always Trust."
