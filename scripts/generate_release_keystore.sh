#!/usr/bin/env bash
# Run this ONCE on your local machine to generate a stable ClearBridge release
# keystore, then paste the printed values into GitLab CI/CD variables.
#
# Usage:
#   bash scripts/generate_release_keystore.sh
#
# You will be asked to choose a password. Use something memorable and save it
# in your password manager — you need the same password for every future build.
# After running, add four GitLab CI/CD variables:
#   Settings → CI/CD → Variables (protect + mask each one):
#     KEYSTORE_BASE64   ← the base64 block printed below
#     KEYSTORE_PASSWORD ← the password you chose
#     KEY_ALIAS         ← clearbridge-release
#     KEY_PASSWORD      ← same as KEYSTORE_PASSWORD
#
# Once these four variables are set, every GitLab CI build will sign with this
# same stable cert and Android upgrades will work without uninstalling first.

set -euo pipefail

KEYSTORE="clearbridge_release.keystore"
ALIAS="clearbridge-release"

echo ""
echo "=== ClearBridge Release Keystore Generator ==="
echo ""
echo "Choose a strong password (you will need it forever — save it now):"
read -r -s -p "Password: " PASSWORD
echo ""
read -r -s -p "Confirm:  " PASSWORD2
echo ""
if [ "$PASSWORD" != "$PASSWORD2" ]; then
  echo "Passwords don't match. Exiting." >&2
  exit 1
fi

echo ""
echo "Generating 4096-bit RSA keystore valid for 100 years..."
keytool -genkeypair -v \
  -keystore "$KEYSTORE" \
  -storepass "$PASSWORD" \
  -alias "$ALIAS" \
  -keypass "$PASSWORD" \
  -keyalg RSA -keysize 4096 -validity 36500 \
  -dname "CN=ClearBridge,O=ClearBridge,C=ZA"

echo ""
echo "=== Certificate Fingerprint (keep for Firebase App Check registration) ==="
keytool -list -v \
  -keystore "$KEYSTORE" \
  -storepass "$PASSWORD" \
  -alias "$ALIAS" 2>/dev/null | grep -E "SHA256:|Owner:|Alias"

echo ""
echo "=== KEYSTORE_BASE64 (paste into GitLab CI/CD variable) ==="
echo ""
base64 -w 0 "$KEYSTORE"
echo ""
echo ""
echo "=== Done. GitLab CI/CD variables to set ==="
echo "  KEYSTORE_BASE64   = <the base64 block above>"
echo "  KEYSTORE_PASSWORD = $PASSWORD"
echo "  KEY_ALIAS         = $ALIAS"
echo "  KEY_PASSWORD      = $PASSWORD"
echo ""
echo "IMPORTANT: Delete $KEYSTORE from this folder after saving the base64."
echo "The keystore lives in GitLab — you don't need the local file."
echo "GitLab → Project → Settings → CI/CD → Variables → Add variable"
echo "  Protect: yes, Mask: yes (for passwords), Environment: All"
