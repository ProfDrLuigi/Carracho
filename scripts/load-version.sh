#!/bin/sh
# Loads the single Carracho version source used by Xcode, Swift and native Linux builds.
: "${ROOT:?ROOT must point at the Carracho repository root}"

VERSION_FILE="${CARRACHO_VERSION_FILE:-$ROOT/Version.xcconfig}"

version_value() {
    key="$1"
    awk -F= -v key="$key" '
        {
            name=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            if (name == key) {
                value=substr($0, index($0, "=") + 1)
                sub(/^[[:space:]]+/, "", value)
                sub(/[[:space:]]+$/, "", value)
                print value
                exit
            }
        }
    ' "$VERSION_FILE"
}

[ -f "$VERSION_FILE" ] || {
    echo "error: version configuration not found: $VERSION_FILE" >&2
    exit 1
}

CARRACHO_VERSION="$(version_value MARKETING_VERSION)"
CARRACHO_BUILD="$(version_value CURRENT_PROJECT_VERSION)"

if [ -n "${CARRACHO_VERSION_OVERRIDE:-}" ]; then
    CARRACHO_VERSION="$CARRACHO_VERSION_OVERRIDE"
fi
if [ -n "${CARRACHO_BUILD_OVERRIDE:-}" ]; then
    CARRACHO_BUILD="$CARRACHO_BUILD_OVERRIDE"
fi

case "$CARRACHO_VERSION" in
    ""|*[!0-9A-Za-z.+_~-]*)
        echo "error: invalid MARKETING_VERSION in $VERSION_FILE: $CARRACHO_VERSION" >&2
        exit 1
        ;;
esac

case "$CARRACHO_BUILD" in
    ""|*[!0-9]*)
        echo "error: invalid CURRENT_PROJECT_VERSION in $VERSION_FILE: $CARRACHO_BUILD" >&2
        exit 1
        ;;
esac

export CARRACHO_VERSION CARRACHO_BUILD
