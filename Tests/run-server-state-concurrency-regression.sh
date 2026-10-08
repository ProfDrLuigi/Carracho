#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output="$(mktemp -t carracho-server-state-concurrency)"
trap 'rm -f "$output"' EXIT
xcrun swiftc -o "$output" \
    Carracho/ServerCore/ServerPasswordVerifier.swift \
    Carracho/ServerCore/ServerState.swift \
    Carracho/ServerCore/ServerStateStore.swift \
    Carracho/ServerCore/OfflineMessageStore.swift \
    Carracho/ServerCore/ModernServerBackend.swift \
    Tests/ServerStateConcurrencyRegression.swift -lsqlite3
"$output"
