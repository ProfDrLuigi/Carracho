#!/bin/bash
set -euo pipefail

PROFILE="${1:-Carracho}"

echo "Storing Apple notarization credentials in the macOS Keychain."
echo "Profile: $PROFILE"
echo
echo "notarytool will prompt for Apple ID, Team ID and an app-specific password."
echo

xcrun notarytool store-credentials "$PROFILE"

echo
echo "Stored notarytool profile '$PROFILE'."
