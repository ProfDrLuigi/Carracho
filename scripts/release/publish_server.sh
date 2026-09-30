#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PROJECT="$ROOT/Carracho.xcodeproj"
SERVER_SCHEME="Carracho Server"

GITHUB_REPO="ProfDrLuigi/Carracho"
GITHUB_ACCOUNT="ProfDrLuigi"
GITHUB_KEYCHAIN_SERVICE="Carracho-GitHub-Publish"

PAGES_BASE="https://profdrLuigi.github.io/Carracho"
BRANCH="${CARRACHO_RELEASE_BRANCH:-main}"

SIGNING_MODE="${CARRACHO_SIGNING_MODE:-none}"
NOTARY_PROFILE="${CARRACHO_NOTARY_PROFILE:-Carracho}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-ed25519}"

say() {
    printf '\n==> %s\n' "$*"
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

git_safe() {
    git -c safe.directory="$ROOT" "$@"
}

restore_xcode_package_lock_if_deleted() {
    local lock="Carracho.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    local status

    status="$(git_safe status --porcelain -- "$lock")"
    if [ "$status" = " D $lock" ]; then
        say "Restoring Package.resolved removed by Xcode package resolution"
        git_safe checkout HEAD -- "$lock"
    fi
}

project_value() {
    local key="$1"
    local values

    values="$(
        sed -n "s/.*${key} = \([^;]*\);/\1/p" \
            "$ROOT/Carracho.xcodeproj/project.pbxproj" \
        | tr -d '"' \
        | sort -u
    )"

    [ -n "$values" ] || die "Could not read $key from project.pbxproj"

    if [ "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" != "1" ]; then
        printf '%s\n' "$values" >&2
        die "$key is not consistent across project configurations"
    fi

    printf '%s' "$values"
}

load_github_token() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        return 0
    fi

    if command -v gh >/dev/null 2>&1; then
        GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
        if [ -n "$GITHUB_TOKEN" ]; then
            export GITHUB_TOKEN
            return 0
        fi
    fi

    GITHUB_TOKEN="$(
        security find-generic-password \
            -a "$GITHUB_ACCOUNT" \
            -s "$GITHUB_KEYCHAIN_SERVICE" \
            -w 2>/dev/null || true
    )"

    [ -n "$GITHUB_TOKEN" ] \
        || die "No GitHub publishing credential found. Run scripts/release/setup_github_token.sh once."

    export GITHUB_TOKEN
}

git_push_with_token() {
    local askpass
    local rc

    askpass="$(mktemp)"
    cat >"$askpass" <<'ASKPASS_EOF'
#!/bin/sh
case "$1" in
    *Username*) printf '%s\n' "x-access-token" ;;
    *) printf '%s\n' "$GITHUB_TOKEN" ;;
esac
ASKPASS_EOF
    chmod 700 "$askpass"

    if GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
        git -c safe.directory="$ROOT" "$@"; then
        rc=0
    else
        rc=$?
    fi

    rm -f "$askpass"
    return "$rc"
}

verify_executables() {
    local app="$1"
    local errors

    errors="$(mktemp)"

    while IFS= read -r -d '' file; do
        if ! codesign --verify --strict --verbose=2 "$file" >/dev/null 2>&1; then
            printf '%s\n' "$file" >>"$errors"
        fi
    done < <(find "$app" -type f -perm -111 -print0)

    if [ -s "$errors" ]; then
        cat "$errors" >&2
        rm -f "$errors"
        die "At least one executable inside the app bundle has an invalid signature"
    fi

    rm -f "$errors"
}

VERSION="$(project_value MARKETING_VERSION)"
BUILD_NUMBER="$(project_value CURRENT_PROJECT_VERSION)"

TAG="Carracho${VERSION}"
ASSET_NAME="Carracho-Server-${VERSION}.zip"
RELEASE_NOTES="$ROOT/README_${VERSION}.md"

WORK_ROOT="$ROOT/.build/publish-server/${VERSION}"
DERIVED_DATA="$WORK_ROOT/DerivedData"
FINAL_APP="$DERIVED_DATA/Build/Products/Release/Carracho Server.app"
FINAL_ZIP="$WORK_ROOT/$ASSET_NAME"
NOTARY_ZIP="$WORK_ROOT/notarization.zip"
FEED_DIR="$WORK_ROOT/feed"

DOCS_RELEASES="$ROOT/docs/releases"
DOCS_SERVER="$ROOT/docs/server"

say "Preparing Carracho Server $VERSION (build $BUILD_NUMBER)"
echo "Apple signing mode: $SIGNING_MODE"

[ -f "$RELEASE_NOTES" ] || die "Missing $RELEASE_NOTES"
grep -Fq "# Carracho $VERSION" "$RELEASE_NOTES" \
    || die "$RELEASE_NOTES has the wrong release title"
grep -Fq "## Highlights" "$RELEASE_NOTES" \
    || die "$RELEASE_NOTES has no Highlights section"
grep -Fq "## Carracho Server $VERSION" "$RELEASE_NOTES" \
    || die "$RELEASE_NOTES has no server release section"

[ "$(git_safe branch --show-current)" = "$BRANCH" ] \
    || die "Releases must be published from branch '$BRANCH'"

restore_xcode_package_lock_if_deleted

DIRTY_STATUS="$(
    git_safe status --porcelain \
    | grep -Ev '^\?\? .*\.DS_Store$|^\?\? Carracho\.xcodeproj/project\.xcworkspace/xcuserdata/' \
    || true
)"

if [ -n "$DIRTY_STATUS" ]; then
    printf '%s\n' "$DIRTY_STATUS" >&2
    die "Working tree is not clean. Commit the release source and metadata before publishing."
fi

load_github_token

say "Checking GitHub branch state"
git_safe fetch origin "$BRANCH" --tags
git_safe merge-base --is-ancestor "origin/$BRANCH" HEAD \
    || die "Local $BRANCH is behind or diverged from origin/$BRANCH"

say "Rendering release notes, changelog and GitHub Pages metadata"
python3 "$ROOT/scripts/release/render_release.py" \
    --version "$VERSION" \
    --build "$BUILD_NUMBER" \
    --notes "$RELEASE_NOTES" \
    --root-readme "$ROOT/README.md" \
    --server-changelog "$ROOT/carrachoserver.html" \
    --docs-index "$ROOT/docs/index.html" \
    --docs-releases "$DOCS_RELEASES"

git_safe diff --check

if [ -n "$(
    git_safe status --porcelain -- \
        README.md \
        carrachoserver.html \
        docs/index.html \
        docs/releases
)" ]; then
    git_safe add \
        README.md \
        carrachoserver.html \
        docs/index.html \
        docs/releases
    git_safe commit -m "Prepare Carracho Server $VERSION release"
fi

case "$SIGNING_MODE" in
    none)
        say "Building Release app without Developer ID (Team: None)"
        rm -rf "$DERIVED_DATA"
        mkdir -p "$WORK_ROOT"

        xcodebuild \
            -project "$PROJECT" \
            -scheme "$SERVER_SCHEME" \
            -configuration Release \
            -derivedDataPath "$DERIVED_DATA" \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            DEVELOPMENT_TEAM="" \
            clean build

        restore_xcode_package_lock_if_deleted

        [ -d "$FINAL_APP" ] \
            || die "Release app was not produced at $FINAL_APP"

        say "Apple Developer ID signing disabled; Team: None"
        echo "Xcode may apply an ad-hoc/linker signature, but no Apple Team ID is used."
        echo "Skipping Developer ID verification, notarization, stapling and Gatekeeper assessment."
        ;;

    developer-id)
        say "Locating Developer ID Application certificate"
        IDENTITY="${CARRACHO_DEVELOPER_IDENTITY:-}"

        if [ -z "$IDENTITY" ]; then
            IDENTITY="$(
                security find-identity -v -p codesigning 2>/dev/null \
                | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
                | head -n1
            )"
        fi

        [ -n "$IDENTITY" ] \
            || die "No Developer ID Application certificate found in the login keychain"

        TEAM_ID="$(
            printf '%s' "$IDENTITY" \
            | sed -n 's/.*(\([A-Z0-9][A-Z0-9]*\))$/\1/p'
        )"

        [ -n "$TEAM_ID" ] \
            || die "Could not derive the Apple Team ID from Developer ID identity: $IDENTITY"

        say "Building Developer ID signed Release app"
        rm -rf "$DERIVED_DATA"
        mkdir -p "$WORK_ROOT"

        xcodebuild \
            -project "$PROJECT" \
            -scheme "$SERVER_SCHEME" \
            -configuration Release \
            -derivedDataPath "$DERIVED_DATA" \
            CODE_SIGN_STYLE=Manual \
            CODE_SIGN_IDENTITY="$IDENTITY" \
            DEVELOPMENT_TEAM="$TEAM_ID" \
            ENABLE_HARDENED_RUNTIME=YES \
            clean build

        restore_xcode_package_lock_if_deleted

        [ -d "$FINAL_APP" ] \
            || die "Release app was not produced at $FINAL_APP"

        say "Verifying code signatures"
        codesign --verify --deep --strict --verbose=4 "$FINAL_APP"
        verify_executables "$FINAL_APP"

        say "Notarizing Release app"
        rm -f "$NOTARY_ZIP"
        ditto -c -k --sequesterRsrc --keepParent \
            "$FINAL_APP" \
            "$NOTARY_ZIP"

        if ! xcrun notarytool submit "$NOTARY_ZIP" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait; then
            die "Notarization failed. Configure the '$NOTARY_PROFILE' notarytool profile as documented in scripts/release/README.md."
        fi

        xcrun stapler staple "$FINAL_APP"
        xcrun stapler validate "$FINAL_APP"
        spctl --assess --type execute --verbose=4 "$FINAL_APP"
        ;;

    *)
        die "Unsupported CARRACHO_SIGNING_MODE '$SIGNING_MODE' (use 'none' or 'developer-id')"
        ;;
esac

say "Creating final Sparkle ZIP"
rm -f "$FINAL_ZIP"
ditto -c -k --sequesterRsrc --keepParent \
    "$FINAL_APP" \
    "$FINAL_ZIP"

say "Generating Sparkle appcast for GitHub"
SPARKLE_TOOL="$(
    find "$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin" \
        -maxdepth 1 \
        -type f \
        -name generate_appcast \
        -perm -111 \
        2>/dev/null \
    | head -n1
)"

[ -x "$SPARKLE_TOOL" ] \
    || die "Sparkle generate_appcast was not found in DerivedData"

rm -rf "$FEED_DIR"
mkdir -p "$FEED_DIR" "$DOCS_SERVER" "$DOCS_RELEASES"

cp "$FINAL_ZIP" "$FEED_DIR/$ASSET_NAME"
cp "$DOCS_RELEASES/Carracho-Server-${VERSION}.html" \
   "$FEED_DIR/Carracho-Server-${VERSION}.html"

if [ -f "$DOCS_SERVER/appcast.xml" ]; then
    cp "$DOCS_SERVER/appcast.xml" "$FEED_DIR/appcast.xml"
fi

"$SPARKLE_TOOL" \
    --account "$SPARKLE_KEY_ACCOUNT" \
    --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/$TAG/" \
    --release-notes-url-prefix "$PAGES_BASE/releases/" \
    --link "$PAGES_BASE/" \
    --maximum-versions 0 \
    --maximum-deltas 0 \
    "$FEED_DIR"

[ -f "$FEED_DIR/appcast.xml" ] \
    || die "Sparkle did not generate appcast.xml"
grep -Fq "$ASSET_NAME" "$FEED_DIR/appcast.xml" \
    || die "Generated appcast does not reference $ASSET_NAME"
grep -Fq "sparkle:edSignature" "$FEED_DIR/appcast.xml" \
    || die "Generated appcast contains no EdDSA signature"
xmllint --noout "$FEED_DIR/appcast.xml"

cp "$FEED_DIR/appcast.xml" "$DOCS_SERVER/appcast.xml"

# Existing 1.1.2 Server installations still poll the historical feed URL.
# If the old staging directory is mounted, keep it as a one-release bridge.
LEGACY_FEED_DIR="${CARRACHO_LEGACY_SERVER_FEED_DIR:-/Volumes/Homeshare/Xcode/CarrachoServer/upload}"

if [ -d "$LEGACY_FEED_DIR" ]; then
    say "Updating optional legacy feed bridge in $LEGACY_FEED_DIR"

    cp "$DOCS_SERVER/appcast.xml" "$LEGACY_FEED_DIR/appcast.xml"
    cp "$ROOT/carrachoserver.html" "$LEGACY_FEED_DIR/carrachoserver.html"

    if [ -n "${CARRACHO_LEGACY_FEED_SYNC_COMMAND:-}" ] \
        && [ -x "$CARRACHO_LEGACY_FEED_SYNC_COMMAND" ]; then
        "$CARRACHO_LEGACY_FEED_SYNC_COMMAND"
    fi
fi

git_safe diff --check

if [ -n "$(git_safe status --porcelain -- docs/server/appcast.xml)" ]; then
    git_safe add docs/server/appcast.xml
    git_safe commit -m "Publish Carracho Server $VERSION appcast"
fi

say "Creating/verifying release tag $TAG"
if git_safe rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    TAG_COMMIT="$(git_safe rev-list -n1 "$TAG")"
    HEAD_COMMIT="$(git_safe rev-parse HEAD)"

    [ "$TAG_COMMIT" = "$HEAD_COMMIT" ] \
        || die "Tag $TAG already exists at a different commit"
else
    git_safe tag -a "$TAG" -m "Carracho $VERSION"
fi

say "Pushing release tag to GitHub"
git_push_with_token push origin "$TAG"

say "Creating/updating GitHub Release and uploading $ASSET_NAME"
python3 "$ROOT/scripts/release/github_release.py" \
    --repo "$GITHUB_REPO" \
    --tag "$TAG" \
    --title "Carracho $VERSION" \
    --notes "$RELEASE_NOTES" \
    --asset "$FINAL_ZIP" \
    --target "$BRANCH"

say "Publishing website and Sparkle appcast on $BRANCH"
git_push_with_token push origin "$BRANCH"

say "Copying published Server app to Desktop"
DESKTOP_APP="$HOME/Desktop/Carracho Server.app"
rm -rf "$DESKTOP_APP"
ditto "$FINAL_APP" "$DESKTOP_APP"

say "Publish complete"
echo "GitHub Release: https://github.com/$GITHUB_REPO/releases/tag/$TAG"
echo "Sparkle feed:   $PAGES_BASE/server/appcast.xml"
echo "Website:        $PAGES_BASE/"
echo "Artifact:       $FINAL_ZIP"
