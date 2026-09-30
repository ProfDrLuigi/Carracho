# Carracho release automation

The Xcode aggregate target **Publish Carracho Server** calls `publish_server.sh`.

## One-time setup

### GitHub

Run:

```sh
scripts/release/setup_github_token.sh
```

Use a fine-grained GitHub token for `ProfDrLuigi/Carracho` with **Contents: Read and write** permission. The token is stored in the macOS Keychain, not in the repository.

If `gh` is installed and authenticated, or `GITHUB_TOKEN` is supplied in the environment, the publisher can use those instead.

### Apple signing / notarization

Apple Developer ID signing is **optional**. The publisher defaults to:

```text
CARRACHO_SIGNING_MODE=none
```

In this mode Xcode builds the Release app with **Team: None** using `CODE_SIGNING_ALLOWED=NO`. No Developer ID certificate or Apple Team ID is required. Xcode/the linker may still place an ad-hoc signature on Mach-O executables, but there is no Developer ID identity (`TeamIdentifier` is unset). The publisher skips Developer ID verification, notarization, stapling and Gatekeeper assessment. Sparkle EdDSA signing remains enabled and still protects the update archive/appcast.

If a Developer ID certificate is available later, opt in with:

```sh
CARRACHO_SIGNING_MODE=developer-id scripts/release/publish_server.sh
```

For that optional mode, store a notarytool profile once with `scripts/release/setup_notary.sh`.

**Important:** an app without Developer ID/notarization can trigger macOS Gatekeeper warnings when downloaded from the Internet. Sparkle signature verification does not replace Apple's Developer ID/notarization trust path.

### Sparkle signing

The existing server `SUPublicEDKey` is retained. `generate_appcast` reads the matching EdDSA private key from the login Keychain account `ed25519` by default. Override the keychain account with `SPARKLE_KEY_ACCOUNT`.

## Release prerequisites

Before running the target:

- set `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`;
- add `README_<version>.md` with a `## Carracho Server <version>` section;
- commit the source changes;
- keep the tracked working tree clean.

The target then prepares website/changelog metadata, builds the Release app using the selected Apple signing mode, creates the Sparkle archive/appcast, creates or updates the GitHub Release, uploads the ZIP, commits the generated appcast/website files, and pushes everything to GitHub.

## Migrating the old Sparkle feed

Carracho Server 1.1.3 changes `SUFeedURL` from the historical `wired.istation.pw` feed to GitHub Pages. Existing 1.1.2 installations still poll the historical URL, so that old endpoint must expose the 1.1.3 bridge appcast once (or redirect to the GitHub Pages appcast).

When `/Volumes/Homeshare/Xcode/CarrachoServer/upload` exists, the publisher copies the generated GitHub appcast and server changelog there. If `CARRACHO_LEGACY_FEED_SYNC_COMMAND` points to an executable, it is invoked afterwards so the historical endpoint can be synchronized without changing the new GitHub-first release flow.
