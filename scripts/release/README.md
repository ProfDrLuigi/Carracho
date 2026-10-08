# Carracho release automation

The Xcode aggregate targets **Publish Carracho** and **Publish Carracho Server** build from the **same source repository and Xcode project**, but publish to **independent GitHub Releases**:

```text
ProfDrLuigi/Carracho                  source code + Client Releases
  tag Carracho1.1.9                   Carracho-Client-1.1.9.zip

ProfDrLuigi/Carracho-Server           Server downloads + changelog ONLY
  tag v1.1.7                          Carracho-Server-1.1.7.zip
  README.md                           downloads and source link
  CHANGELOG.md                        independent Server history
```

Server archives are GitHub Release assets, **not files committed to Git**. The Server release notes are extracted from the `## Carracho Server <version>` section in the shared source notes. The source project is not duplicated into the Server-only repository.

Existing Server installations keep polling `https://profdrLuigi.github.io/Carracho/server/appcast.xml` in the original source repository; new Server releases update that legacy feed with **ZIP download links pointing to Carracho-Server**. Do not remove or redirect this feed until all old installations have migrated. Historical appcast items retain their original URLs and signatures.

## One-time setup

### GitHub

Run:

```sh
scripts/release/setup_github_token.sh
```

The fine-grained GitHub token must authorize **both** `ProfDrLuigi/Carracho` and `ProfDrLuigi/Carracho-Server` with **Contents: Read and write**. The existing credential is stored in the macOS login Keychain service `Carracho-GitHub-Publish` and is used by both publishers. When creating the new repository, edit the token's **Repository access** to include it; creating a repo does not automatically extend an existing selected-repository token. Never copy the token into source files, release notes or chat messages.

### Apple signing / notarization

Apple Developer ID signing is optional. Both publishers default to:

```text
CARRACHO_SIGNING_MODE=none
```

In this mode Xcode builds with **Team: None** and no Developer ID certificate. After Sparkle is embedded, the publisher ad-hoc re-seals the Sparkle framework wrapper and the outer app bundle so Sparkle's archive verification succeeds. Developer ID notarization, stapling and Gatekeeper assessment are skipped.

To opt into Developer ID signing later:

```sh
CARRACHO_SIGNING_MODE=developer-id scripts/release/publish_client.sh
CARRACHO_SIGNING_MODE=developer-id scripts/release/publish_server.sh
```

For that optional mode, configure the notarytool profile once with `scripts/release/setup_notary.sh`.

**Important:** Sparkle EdDSA signing protects update integrity but does not replace Apple's Developer ID/notarization trust path for direct Internet downloads.

### Sparkle signing

Client and Server use the existing `SUPublicEDKey`. `generate_appcast` reads the matching EdDSA private key from the login Keychain account `ed25519` by default. Override it with `SPARKLE_KEY_ACCOUNT`.

## Version sources

Client and Server versions are intentionally independent:

```text
Version-Client.xcconfig
  MARKETING_VERSION = <client version>
  CURRENT_PROJECT_VERSION = <client build>

Version-Server.xcconfig
  MARKETING_VERSION = <server version>
  CURRENT_PROJECT_VERSION = <server build>
```

The macOS Client target inherits `Version-Client.xcconfig`. The macOS Server, native Linux Server and Debian packages use `Version-Server.xcconfig`. Swift reads each app's generated bundle values through `CarrachoBuildInfo`.

`Release.xcconfig` determines the **shared release documentation title and Client GitHub tag**:

```text
Release.xcconfig
  CARRACHO_RELEASE_VERSION = <client documentation release version>
```

The **Server** independently tags releases as `v<Version-Server.xcconfig MARKETING_VERSION>` in `ProfDrLuigi/Carracho-Server`. Its ZIP and server changelog are named from `Version-Server.xcconfig`, not the Client release version. No shared GitHub tag or server ZIP upload is performed in the source repository.

For scripted overrides, use `CARRACHO_CLIENT_VERSION_OVERRIDE` / `CARRACHO_CLIENT_BUILD_OVERRIDE` or `CARRACHO_SERVER_VERSION_OVERRIDE` / `CARRACHO_SERVER_BUILD_OVERRIDE`. The older generic `CARRACHO_VERSION_OVERRIDE` / `CARRACHO_BUILD_OVERRIDE` remain fallback overrides for one-product tooling such as Debian package builds.

## Release prerequisites

Before running either publisher:

- `Version-Client.xcconfig` must contain the intended Client version/build;
- `Version-Server.xcconfig` must contain the intended Server version/build;
- `Release.xcconfig` must contain the shared source documentation / Client release version;
- `README_<release version>.md` must contain `## Highlights`, `## Carracho Client <client version>`, and `## Carracho Server <server version>`;
- source changes must be committed;
- the tracked working tree must be clean.

Both publishers render the same website/release metadata. They generate product-specific release-note pages:

```text
docs/releases/Carracho-Client-<client version>.html
docs/releases/Carracho-Server-<server version>.html
```

The Sparkle feeds stay separate:

```text
docs/client/appcast.xml
docs/server/appcast.xml
```

The Client appcast downloads ZIP assets from `Carracho`. New Server appcast entries download ZIP assets from `Carracho-Server`, while historical Server entries continue using the URLs they were originally signed for.

## Xcode targets

**Publish Carracho** calls:

```text
scripts/release/publish_client.sh
```

**Publish Carracho Server** calls:

```text
scripts/release/publish_server.sh
```

Client publishing is unchanged. Server publishing renders Server-only release notes and `README.md`/`CHANGELOG.md`, synchronizes only those two Markdown files to `Carracho-Server/main`, publishes `Carracho-Server-<version>.zip` to a `v<version>` Release in that repository, and updates the **existing** legacy Server appcast in `Carracho/main` for previously installed Servers. Neither Server source files nor server ZIP binaries are committed to `Carracho-Server`.

To prepare metadata locally without publishing, run `python3 -B scripts/release/server_release_notes.py --source . --output .build/server-release-preview --version 1.1.7 --build 18`. Both publishers require their respective GitHub permissions and a clean source worktree before an actual publish.

Release builds are forced to **Universal 2** (`arm64 + x86_64`) with a generic macOS destination. Before signing, notarization or upload, the publisher checks every Mach-O file in the app bundle with `lipo` and aborts unless both architecture slices are present.

When a build number is republished, the publisher removes that existing item from the copied appcast before running Sparkle's `generate_appcast`. This forces Sparkle to re-infer system and hardware metadata from the new archive instead of preserving stale branch metadata from the previous artifact. The generated item is then rejected if it still declares an `arm64` hardware requirement for the Universal 2 build.

## Migrating the old Sparkle feeds

The GitHub-first feeds are:

```text
https://profdrLuigi.github.io/Carracho/client/appcast.xml
https://profdrLuigi.github.io/Carracho/server/appcast.xml
```

Older installations still polling `wired.istation.pw` need a bridge update once.

When the legacy staging directories exist, the publishers copy the new appcast plus the corresponding historical changelog into them:

```text
/Volumes/Homeshare/Xcode/CarrachoClient/upload
/Volumes/Homeshare/Xcode/CarrachoServer/upload
```

Optional sync hooks can be supplied with `CARRACHO_LEGACY_CLIENT_FEED_SYNC_COMMAND` and `CARRACHO_LEGACY_FEED_SYNC_COMMAND`.
