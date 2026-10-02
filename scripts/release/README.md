# Carracho release automation

The Xcode aggregate targets **Publish Carracho** and **Publish Carracho Server** publish the macOS Client and Server through the same GitHub/Sparkle release flow.

Both products use the same version tag and the same GitHub Release:

```text
Carracho<version>
├── Carracho-Client-<version>.zip
└── Carracho-Server-<version>.zip
```

Whichever product is published first creates the shared tag/release. Publishing the other product for the same version preserves the existing tag and adds or replaces only its own ZIP asset.

## One-time setup

### GitHub

Run:

```sh
scripts/release/setup_github_token.sh
```

Use a fine-grained GitHub token for `ProfDrLuigi/Carracho` with **Contents: Read and write** permission. The dedicated token is stored in the macOS Keychain service `Carracho-GitHub-Publish` and is preferred by both publishers.

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

The shared GitHub release/tag is a separate value:

```text
Release.xcconfig
  CARRACHO_RELEASE_VERSION = <release version>
```

This lets one GitHub Release contain different product versions, for example Client 1.1.5 and Server 1.1.4. Both ZIP assets still use their own product version in the filename and Sparkle feed.

For scripted overrides, use `CARRACHO_CLIENT_VERSION_OVERRIDE` / `CARRACHO_CLIENT_BUILD_OVERRIDE` or `CARRACHO_SERVER_VERSION_OVERRIDE` / `CARRACHO_SERVER_BUILD_OVERRIDE`. The older generic `CARRACHO_VERSION_OVERRIDE` / `CARRACHO_BUILD_OVERRIDE` remain fallback overrides for one-product tooling such as Debian package builds.

## Release prerequisites

Before running either publisher:

- `Version-Client.xcconfig` must contain the intended Client version/build;
- `Version-Server.xcconfig` must contain the intended Server version/build;
- `Release.xcconfig` must contain the shared GitHub release version;
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

Both feeds point their enclosure URLs at the corresponding ZIP asset inside the same GitHub Release.

## Xcode targets

**Publish Carracho** calls:

```text
scripts/release/publish_client.sh
```

**Publish Carracho Server** calls:

```text
scripts/release/publish_server.sh
```

Each publisher builds its own app, creates its ZIP/appcast, uploads its own asset to the shared GitHub Release, commits generated feed metadata, pushes `main`, and copies the published app to the Desktop.

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
