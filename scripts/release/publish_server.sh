#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PROJECT="$ROOT/Carracho.xcodeproj"
SERVER_SCHEME="Carracho Server"

# ZIPs, changelog and tags live in a Server-only GitHub repository.
# Source code, the Xcode project, the legacy Sparkle feed and website remain in Carracho.
GITHUB_REPO="ProfDrLuigi/Carracho-Server"
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


load_github_token() {
    local inherited_github_token="${GITHUB_TOKEN:-}"

    # Use a Carracho-specific override only when explicitly requested.
    if [ -n "${CARRACHO_GITHUB_TOKEN:-}" ]; then
        GITHUB_TOKEN="$CARRACHO_GITHUB_TOKEN"
        GITHUB_TOKEN_SOURCE="CARRACHO_GITHUB_TOKEN"
        export GITHUB_TOKEN GITHUB_TOKEN_SOURCE
        return 0
    fi

    # The release setup stores the authoritative publishing token here.
    GITHUB_TOKEN="$(
        security find-generic-password \
            -a "$GITHUB_ACCOUNT" \
            -s "$GITHUB_KEYCHAIN_SERVICE" \
            -w 2>/dev/null || true
    )"

    if [ -n "$GITHUB_TOKEN" ]; then
        GITHUB_TOKEN_SOURCE="macOS Keychain ($GITHUB_KEYCHAIN_SERVICE)"
        export GITHUB_TOKEN GITHUB_TOKEN_SOURCE
        return 0
    fi

    # Fallbacks are useful outside the normal Xcode release path, but they must
    # not silently override the dedicated Carracho publishing credential.
    if [ -n "$inherited_github_token" ]; then
        GITHUB_TOKEN="$inherited_github_token"
        GITHUB_TOKEN_SOURCE="GITHUB_TOKEN"
        export GITHUB_TOKEN GITHUB_TOKEN_SOURCE
        return 0
    fi

    if command -v gh >/dev/null 2>&1; then
        GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
        if [ -n "$GITHUB_TOKEN" ]; then
            GITHUB_TOKEN_SOURCE="gh auth token"
            export GITHUB_TOKEN GITHUB_TOKEN_SOURCE
            return 0
        fi
    fi

    die "No GitHub publishing credential found. Run scripts/release/setup_github_token.sh once."
}

verify_github_release_permission() {
    python3 - "$GITHUB_REPO" <<'PYTHON'
import os
import sys
import urllib.error
import urllib.request

repo = sys.argv[1]
token = os.environ.get("GITHUB_TOKEN", "")
url = f"https://api.github.com/repos/{repo}/releases"

request = urllib.request.Request(url, data=b"{}", method="POST")
request.add_header("Accept", "application/vnd.github+json")
request.add_header("Authorization", f"Bearer {token}")
request.add_header("Content-Type", "application/json")
request.add_header("X-GitHub-Api-Version", "2022-11-28")

try:
    with urllib.request.urlopen(request):
        print("Unexpected success from GitHub release permission preflight", file=sys.stderr)
        raise SystemExit(2)
except urllib.error.HTTPError as exc:
    accepted = exc.headers.get("X-Accepted-GitHub-Permissions", "")

    if exc.code == 422:
        print("GitHub release permission preflight: OK")
        if accepted:
            print(f"GitHub accepted permissions: {accepted}")
        raise SystemExit(0)

    payload = exc.read().decode("utf-8", "replace")
    print(f"GitHub release permission preflight failed ({exc.code}): {payload}", file=sys.stderr)
    if accepted:
        print(f"Required GitHub permissions: {accepted}", file=sys.stderr)
    raise SystemExit(1)
except urllib.error.URLError as exc:
    print(f"GitHub release permission preflight failed: {exc}", file=sys.stderr)
    raise SystemExit(1)
PYTHON
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
        git -c safe.directory="$ROOT" -c credential.helper= "$@"; then
        rc=0
    else
        rc=$?
    fi

    rm -f "$askpass"
    return "$rc"
}

github_release_exists() {
    local repo="$1"
    local tag="$2"

    python3 - "$repo" "$tag" <<'PYTHON'
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

repo, tag = sys.argv[1:3]
token = os.environ.get("GITHUB_TOKEN", "")
if not token:
    print("GITHUB_TOKEN is not set", file=sys.stderr)
    raise SystemExit(2)

encoded_tag = urllib.parse.quote(tag, safe="")
url = f"https://api.github.com/repos/{repo}/releases/tags/{encoded_tag}"
request = urllib.request.Request(url, method="GET")
request.add_header("Accept", "application/vnd.github+json")
request.add_header("Authorization", f"Bearer {token}")
request.add_header("X-GitHub-Api-Version", "2022-11-28")

try:
    with urllib.request.urlopen(request):
        raise SystemExit(0)
except urllib.error.HTTPError as exc:
    if exc.code == 404:
        raise SystemExit(1)

    payload = exc.read().decode("utf-8", "replace")
    print(f"GitHub API GET {url} failed ({exc.code}): {payload}", file=sys.stderr)
    raise SystemExit(2) from exc
except urllib.error.URLError as exc:
    print(f"GitHub API GET {url} failed: {exc}", file=sys.stderr)
    raise SystemExit(2) from exc
PYTHON
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

verify_universal_app() {
    local app="$1"
    local file
    local archs
    local executable_name
    local executable
    local found_macho=0
    local failed=0

    while IFS= read -r -d '' file; do
        if /usr/bin/file -b "$file" 2>/dev/null | grep -q 'Mach-O'; then
            found_macho=1
            archs="$(/usr/bin/lipo -archs "$file" 2>/dev/null || true)"

            if [[ " $archs " != *" arm64 "* || " $archs " != *" x86_64 "* ]]; then
                printf 'ERROR: non-Universal-2 Mach-O: %s (%s)\n' "$file" "${archs:-unknown}" >&2
                failed=1
            fi
        fi
    done < <(find "$app" -type f -print0)

    [ "$found_macho" = "1" ] || die "No Mach-O binaries were found in $app"
    [ "$failed" = "0" ] || die "App bundle contains Mach-O code that is not Universal 2"

    executable_name="$(
        /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null
    )"
    executable="$app/Contents/MacOS/$executable_name"
    archs="$(/usr/bin/lipo -archs "$executable" 2>/dev/null)"

    say "Verified Universal 2 app bundle"
    echo "$executable: $archs"
}

# Product versions are independent; GitHub release identity is shared.
. "$ROOT/scripts/load-version.sh" client
CLIENT_VERSION="$CARRACHO_VERSION"
CLIENT_BUILD="$CARRACHO_BUILD"
RELEASE_VERSION="$CARRACHO_RELEASE_VERSION"

. "$ROOT/scripts/load-version.sh" server
SERVER_VERSION="$CARRACHO_VERSION"
SERVER_BUILD="$CARRACHO_BUILD"

VERSION="$SERVER_VERSION"
BUILD_NUMBER="$SERVER_BUILD"

TAG="v${SERVER_VERSION}"
ASSET_NAME="Carracho-Server-${VERSION}.zip"
SOURCE_RELEASE_NOTES="$ROOT/README_${RELEASE_VERSION}.md"
WORK_ROOT="$ROOT/.build/publish-server/${VERSION}"
RELEASE_REPO_CONTENT="$WORK_ROOT/server-release-repo-content"
RELEASE_NOTES="$RELEASE_REPO_CONTENT/RELEASE_NOTES_${VERSION}.md"
DERIVED_DATA="$WORK_ROOT/DerivedData"
FINAL_APP="$DERIVED_DATA/Build/Products/Release/Carracho Server.app"
FINAL_ZIP="$WORK_ROOT/$ASSET_NAME"
NOTARY_ZIP="$WORK_ROOT/notarization.zip"
FEED_DIR="$WORK_ROOT/feed"

DOCS_RELEASES="$ROOT/docs/releases"
DOCS_SERVER="$ROOT/docs/server"

say "Preparing Carracho Server $VERSION (build $BUILD_NUMBER) for independent repository $GITHUB_REPO"
echo "Apple signing mode: $SIGNING_MODE"

[ -f "$SOURCE_RELEASE_NOTES" ] || die "Missing $SOURCE_RELEASE_NOTES"
grep -Fq "# Carracho $RELEASE_VERSION" "$SOURCE_RELEASE_NOTES" \
    || die "$SOURCE_RELEASE_NOTES has the wrong release title"
grep -Fq "## Highlights" "$SOURCE_RELEASE_NOTES" \
    || die "$SOURCE_RELEASE_NOTES has no Highlights section"
grep -Fq "## Carracho Client $CLIENT_VERSION" "$SOURCE_RELEASE_NOTES" \
    || die "$SOURCE_RELEASE_NOTES has no client release section"
grep -Fq "## Carracho Server $SERVER_VERSION" "$SOURCE_RELEASE_NOTES" \
    || die "$SOURCE_RELEASE_NOTES has no server release section"

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
echo "GitHub credential source: $GITHUB_TOKEN_SOURCE"

say "Checking GitHub release permission"
verify_github_release_permission

say "Checking GitHub branch state"
git_safe fetch --no-tags origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
git_safe merge-base --is-ancestor "origin/$BRANCH" HEAD \
    || die "Local $BRANCH is behind or diverged from origin/$BRANCH"

say "Rendering release notes, changelog and GitHub Pages metadata"
python3 "$ROOT/scripts/release/render_release.py" \
    --release-version "$RELEASE_VERSION" \
    --client-version "$CLIENT_VERSION" \
    --client-build "$CLIENT_BUILD" \
    --server-version "$SERVER_VERSION" \
    --server-build "$SERVER_BUILD" \
    --notes "$SOURCE_RELEASE_NOTES" \
    --root-readme "$ROOT/README.md" \
    --client-changelog "$ROOT/carrachoclient.html" \
    --server-changelog "$ROOT/carrachoserver.html" \
    --docs-index "$ROOT/docs/index.html" \
    --docs-releases "$DOCS_RELEASES"

git_safe diff --check

say "Rendering Server-only release notes and changelog for $GITHUB_REPO"
python3 "$ROOT/scripts/release/server_release_notes.py" \
    --source "$ROOT" \
    --output "$RELEASE_REPO_CONTENT" \
    --version "$VERSION" \
    --build "$BUILD_NUMBER"

if [ -n "$(
    git_safe status --porcelain -- \
        README.md \
        carrachoclient.html \
        carrachoserver.html \
        docs/index.html \
        docs/releases
)" ]; then
    git_safe add \
        README.md \
        carrachoclient.html \
        carrachoserver.html \
        docs/index.html \
        docs/releases
    git_safe commit -m "Prepare Carracho $RELEASE_VERSION release"
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
            -destination "generic/platform=macOS" \
            -derivedDataPath "$DERIVED_DATA" \
            ARCHS="arm64 x86_64" \
            ONLY_ACTIVE_ARCH=NO \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            DEVELOPMENT_TEAM="" \
            clean build

        restore_xcode_package_lock_if_deleted

        [ -d "$FINAL_APP" ] \
            || die "Release app was not produced at $FINAL_APP"

        verify_universal_app "$FINAL_APP"

        # Xcode strips development-only content while embedding Sparkle.framework.
        # With Team: None this leaves the copied framework seal stale and Sparkle's
        # generate_appcast rejects the archive. Re-seal the standalone server daemon
        # helper and the framework wrapper, preserve Sparkle's nested signatures/runtime
        # flags, then seal the outer app ad-hoc. No Apple identity or Team ID is involved.
        SPARKLE_FRAMEWORK="$FINAL_APP/Contents/Frameworks/Sparkle.framework"
        [ -d "$SPARKLE_FRAMEWORK" ] \
            || die "Embedded Sparkle.framework was not found in the Release app"

        DAEMON_HELPER="$FINAL_APP/Contents/Helpers/carracho-serverd"
        if [ ! -x "$DAEMON_HELPER" ]; then
            die "Embedded carracho-serverd helper was not found in the Release app"
        fi

        say "Applying Team-None ad-hoc bundle seals for daemon helper and Sparkle"
        /usr/bin/codesign --force --sign - --timestamp=none "$DAEMON_HELPER"
        /usr/bin/codesign --force --sign - --timestamp=none \
            --preserve-metadata=identifier,entitlements,requirements,flags,runtime \
            "$SPARKLE_FRAMEWORK"
        /usr/bin/codesign --force --sign - --timestamp=none "$FINAL_APP"
        /usr/bin/codesign --verify --deep --strict --verbose=4 "$FINAL_APP"

        say "Apple Developer ID signing disabled; Team: None"
        echo "The app uses an ad-hoc bundle seal only; no Apple Team ID is used."
        echo "Skipping Developer ID notarization, stapling and Gatekeeper assessment."
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
            -destination "generic/platform=macOS" \
            -derivedDataPath "$DERIVED_DATA" \
            ARCHS="arm64 x86_64" \
            ONLY_ACTIVE_ARCH=NO \
            CODE_SIGN_STYLE=Manual \
            CODE_SIGN_IDENTITY="$IDENTITY" \
            DEVELOPMENT_TEAM="$TEAM_ID" \
            ENABLE_HARDENED_RUNTIME=YES \
            clean build

        restore_xcode_package_lock_if_deleted

        [ -d "$FINAL_APP" ] \
            || die "Release app was not produced at $FINAL_APP"

        verify_universal_app "$FINAL_APP"

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

if [ -f "$FEED_DIR/appcast.xml" ]; then
    python3 "$ROOT/scripts/release/appcast_republish.py" \
        drop-version \
        "$FEED_DIR/appcast.xml" \
        "$BUILD_NUMBER"
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
python3 "$ROOT/scripts/release/appcast_republish.py" \
    verify-universal \
    "$FEED_DIR/appcast.xml" \
    "$BUILD_NUMBER"

# The legacy appcast is intentionally kept unchanged in the source working tree
# until the new Server ZIP has been uploaded successfully.
git_safe diff --check

# Upload first. Documentation must not advertise a ZIP that GitHub has rejected.
# github_release.py creates or updates the independent tag v<server-version>
# within the NEW repository. Never tag/publish a Server ZIP in Carracho again.
say "Creating/updating GitHub Release and uploading $ASSET_NAME"
python3 "$ROOT/scripts/release/github_release.py" \
    --repo "$GITHUB_REPO" \
    --tag "$TAG" \
    --title "Carracho Server $VERSION" \
    --notes "$RELEASE_NOTES" \
    --asset "$FINAL_ZIP" \
    --target main


# Source code stays in Carracho. Only the Server README/CHANGELOG are Git-tracked
# in Carracho-Server. ZIP binaries live exclusively as GitHub Release assets.
say "Syncing Server-only README and CHANGELOG to $GITHUB_REPO"
SERVER_REPO_WORKDIR="$WORK_ROOT/server-releases-git"
if [ -d "$SERVER_REPO_WORKDIR/.git" ]; then
    git -C "$SERVER_REPO_WORKDIR" fetch origin main
    git -C "$SERVER_REPO_WORKDIR" checkout main
    git -C "$SERVER_REPO_WORKDIR" merge --ff-only origin/main
else
    git clone "https://github.com/$GITHUB_REPO.git" "$SERVER_REPO_WORKDIR"
fi
cp "$RELEASE_REPO_CONTENT/README.md" "$SERVER_REPO_WORKDIR/README.md"
cp "$RELEASE_REPO_CONTENT/CHANGELOG.md" "$SERVER_REPO_WORKDIR/CHANGELOG.md"
git -C "$SERVER_REPO_WORKDIR" add README.md CHANGELOG.md
if ! git -C "$SERVER_REPO_WORKDIR" diff --cached --quiet; then
    git -C "$SERVER_REPO_WORKDIR" \
        -c user.name="Carracho Release" \
        -c user.email="releases@users.noreply.github.com" \
        commit -m "Update Server release notes for $VERSION"
    git_push_with_token -C "$SERVER_REPO_WORKDIR" push origin main
fi

# Publish the legacy Sparkle feed ONLY after the ZIP exists in Carracho-Server.
# Otherwise a failed GitHub upload would strand old installed Server versions
# with a signed appcast pointing at a 404 archive. The source checkout stays clean
# if the remote release upload fails.
cp "$FEED_DIR/appcast.xml" "$DOCS_SERVER/appcast.xml"
git_safe diff --check
if [ -n "$(git_safe status --porcelain -- docs/server/appcast.xml)" ]; then
    git_safe add docs/server/appcast.xml
    git_safe commit -m "Publish Carracho Server $VERSION appcast"
fi

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
