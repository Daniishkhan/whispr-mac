#!/bin/bash
# Creates a persistent self-signed code-signing certificate named "Whispr Dev"
# and trusts it for code signing.
#
# Signing every build with the same identity means macOS Keychain and
# Accessibility (TCC) grants survive rebuilds. With ad-hoc signing you get
# re-prompted on every binary change.
#
# macOS asks for your login password while this runs: once to trust the
# certificate, and possibly once more to let codesign use its key (choose
# "Always Allow").
set -e

NAME="Whispr Dev"
KEYCHAIN="login.keychain"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# An identity macOS will actually sign with is listed bare; one it rejects is
# listed with a reason after the name, e.g. "(Invalid Key Usage for policy)".
usable_identity() {
    security find-identity -v -p codesigning | grep -q "\"$NAME\"\$"
}

if usable_identity; then
    echo "Certificate '$NAME' already exists and is usable:"
    security find-identity -v -p codesigning | grep "\"$NAME\"\$"
    exit 0
fi

# A leftover from an earlier run that macOS will not sign with: not trusted, or
# created without the key usage code signing requires. Replace it.
attempts=0
while security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 5 ]; then
        echo "Could not remove the existing '$NAME' certificate. Delete it in Keychain Access" >&2
        echo "(login > My Certificates) and run this again." >&2
        exit 1
    fi
    echo "Replacing an existing '$NAME' certificate that macOS will not sign with..."
    security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$TMP/old.pem"
    security remove-trusted-cert "$TMP/old.pem" 2>/dev/null || true
    security delete-identity -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1 \
        || security delete-certificate -c "$NAME" "$KEYCHAIN" >/dev/null
done

echo "Creating self-signed certificate '$NAME'..."
# Code signing needs the digitalSignature key usage as well as the codeSigning
# extended key usage; a certificate with only the latter is refused with
# "Invalid Key Usage for policy".
openssl req -x509 -newkey rsa:2048 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# Check it against the code-signing policy before anything goes in the keychain.
if ! security verify-cert -c "$TMP/cert.pem" -r "$TMP/cert.pem" -p codeSign >/dev/null 2>&1; then
    echo "The generated certificate does not satisfy macOS's code-signing policy:" >&2
    security verify-cert -c "$TMP/cert.pem" -r "$TMP/cert.pem" -p codeSign 2>&1 | tail -1 >&2
    echo "Nothing was added to your keychain. ($(openssl version))" >&2
    exit 1
fi

security import "$TMP/key.pem"  -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security
security import "$TMP/cert.pem" -k "$KEYCHAIN"

echo "Trusting '$NAME' for code signing (macOS will ask for your password)..."
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if ! usable_identity; then
    echo "" >&2
    echo "'$NAME' was imported but is still not usable for code signing:" >&2
    security find-identity -p codesigning | grep "$NAME" >&2 || true
    echo "Open Keychain Access, locate '$NAME' under login > My Certificates," >&2
    echo "then Get Info > Trust > Code Signing > Always Trust." >&2
    exit 1
fi

# Sign a throwaway file now, so the one-time "codesign wants to use this key"
# prompt appears here rather than in the middle of a build.
cp /usr/bin/true "$TMP/probe"
if codesign --force --sign "$NAME" "$TMP/probe" 2>/dev/null; then
    echo ""
    echo "Done. '$NAME' is ready, and 'make app' will sign with it."
else
    echo "" >&2
    echo "'$NAME' is installed and trusted, but codesign could not use its key." >&2
    echo "Run 'make app'; if macOS asks to use the key, choose Always Allow." >&2
    exit 1
fi
