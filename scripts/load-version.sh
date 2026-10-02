#!/bin/sh
# Loads product-specific Carracho version metadata plus the shared GitHub release train.
: "${ROOT:?ROOT must point at the Carracho repository root}"

PRODUCT="${1:-${CARRACHO_PRODUCT:-}}"
CARRACHO_PRODUCT="$PRODUCT"
case "$PRODUCT" in
    client)
        VERSION_FILE="${CARRACHO_CLIENT_VERSION_FILE:-${CARRACHO_VERSION_FILE:-$ROOT/Version-Client.xcconfig}}"
        PRODUCT_VERSION_OVERRIDE="${CARRACHO_CLIENT_VERSION_OVERRIDE:-${CARRACHO_VERSION_OVERRIDE:-}}"
        PRODUCT_BUILD_OVERRIDE="${CARRACHO_CLIENT_BUILD_OVERRIDE:-${CARRACHO_BUILD_OVERRIDE:-}}"
        ;;
    server)
        VERSION_FILE="${CARRACHO_SERVER_VERSION_FILE:-${CARRACHO_VERSION_FILE:-$ROOT/Version-Server.xcconfig}}"
        PRODUCT_VERSION_OVERRIDE="${CARRACHO_SERVER_VERSION_OVERRIDE:-${CARRACHO_VERSION_OVERRIDE:-}}"
        PRODUCT_BUILD_OVERRIDE="${CARRACHO_SERVER_BUILD_OVERRIDE:-${CARRACHO_BUILD_OVERRIDE:-}}"
        ;;
    *)
        echo "error: product must be 'client' or 'server'" >&2
        exit 2
        ;;
esac

RELEASE_FILE="${CARRACHO_RELEASE_FILE:-$ROOT/Release.xcconfig}"

config_value() {
    file="$1"
    key="$2"
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
    ' "$file"
}

[ -f "$VERSION_FILE" ] || {
    echo "error: version configuration not found: $VERSION_FILE" >&2
    exit 1
}
[ -f "$RELEASE_FILE" ] || {
    echo "error: release configuration not found: $RELEASE_FILE" >&2
    exit 1
}

CARRACHO_VERSION="$(config_value "$VERSION_FILE" MARKETING_VERSION)"
CARRACHO_BUILD="$(config_value "$VERSION_FILE" CURRENT_PROJECT_VERSION)"
CARRACHO_RELEASE_VERSION="$(config_value "$RELEASE_FILE" CARRACHO_RELEASE_VERSION)"

if [ -n "$PRODUCT_VERSION_OVERRIDE" ]; then
    CARRACHO_VERSION="$PRODUCT_VERSION_OVERRIDE"
fi
if [ -n "$PRODUCT_BUILD_OVERRIDE" ]; then
    CARRACHO_BUILD="$PRODUCT_BUILD_OVERRIDE"
fi
if [ -n "${CARRACHO_RELEASE_VERSION_OVERRIDE:-}" ]; then
    CARRACHO_RELEASE_VERSION="$CARRACHO_RELEASE_VERSION_OVERRIDE"
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

case "$CARRACHO_RELEASE_VERSION" in
    ""|*[!0-9A-Za-z.+_~-]*)
        echo "error: invalid CARRACHO_RELEASE_VERSION in $RELEASE_FILE: $CARRACHO_RELEASE_VERSION" >&2
        exit 1
        ;;
esac

export CARRACHO_PRODUCT CARRACHO_VERSION CARRACHO_BUILD CARRACHO_RELEASE_VERSION
