#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output="$(mktemp -t carracho-pm-identity)"
trap 'rm -f "$output"' EXIT
xcrun swiftc -o "$output" Carracho/Client/MessageCenterStore.swift Tests/MessageCenterIdentityRegression.swift -lsqlite3
"$output"
