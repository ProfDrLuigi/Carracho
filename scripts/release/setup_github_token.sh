#!/bin/bash
set -euo pipefail

SERVICE="Carracho-GitHub-Publish"
ACCOUNT="ProfDrLuigi"

echo "GitHub fine-grained token for ProfDrLuigi/Carracho AND ProfDrLuigi/Carracho-Server"
echo "Required: both repositories selected, Contents: Read and write."
echo "Existing tokens can be edited on GitHub; no replacement is needed."
echo
read -r -s -p "Token: " TOKEN
echo
if [ -z "$TOKEN" ]; then
  echo "No token entered." >&2
  exit 1
fi

security add-generic-password -U -a "$ACCOUNT" -s "$SERVICE" -w "$TOKEN" >/dev/null
unset TOKEN
echo "Stored in the macOS Keychain as '$SERVICE'."
