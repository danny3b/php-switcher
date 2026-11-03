# Releasing PHP Switcher

Application updates use [Sparkle 2](https://sparkle-project.org/documentation/) and public GitHub Releases in `danny3b/php-switcher`. The application reads the latest stable release's `appcast.xml`, which points to a versioned ZIP asset. Each release also includes a DMG for manual installation by dragging the application into Applications. Keep the repository and release assets public so clients can download without credentials.

## Signing key

The release Ed25519 private key is stored in the maintainer's macOS Keychain under the account `pl.daniel.php-switcher`. Only the public key is committed in `Resources/Info.plist`. Never commit or upload private keys, GitHub credentials, or Keychain exports. Preserve a secure backup of the original signing key separately from this repository; generating a replacement key will not authorize updates for existing installations.

The packaging script checks that the existing Keychain key matches the public key before signing. It signs both the archive and feed. This signature is independent of Apple's Developer ID code signing and notarization. Current builds use an ad hoc application signature and are not notarized.

## Prepare and publish

1. Increase both `CFBundleShortVersionString` (for example, `1.6.1`) and the integer `CFBundleVersion` in `Resources/Info.plist`. Sparkle compares build numbers; never reuse or decrease one.
2. Write English release notes and run the build and relevant tests from the README. Commit the final source on `main`.
3. Prepare the signed archive and appcast on the Mac containing the original signing key:

   ```sh
   bash Scripts/prepare_release.sh
   ```

   Output is in `build/releases/<version>/`: `PHP-Switcher-<version>-arm64.zip`, `PHP-Switcher-<version>-arm64.dmg`, `appcast.xml`, `SHA256SUMS`, a standalone DMG checksum, and a local `SOURCE_REVISION` marker. These files are ignored by Git. Do not edit the signed feed. Re-run preparation after any source changes. The appcast generator receives only the ZIP, so the DMG cannot become a duplicate update entry.

4. Push the source commit, then publish:

   ```sh
   git push origin main
   python3 Scripts/publish_release.py --notes Docs/ReleaseNotes-1.6.1.md --publish
   ```

   Substitute the current release-notes path. The publisher uses the existing Git credential helper; no GitHub CLI or embedded token is needed. It requires a clean working tree, a matching remote `main`, matching packaged source revision, valid signatures, matching archive metadata, and matching checksums. It mounts the DMG read-only, checks the application signature and Applications shortcut, and compares every application file and symbolic link with the ZIP. It first creates a draft, uploads and verifies the ZIP, DMG, appcast, and combined checksums, then publishes it as the latest stable release. Omitting `--publish` leaves a draft.

5. Open the published `releases/latest/download/appcast.xml` without authentication and verify its version and assets. Leave the installed application untouched so the user can check from their older copy and test **Install and restart** themselves. After installation, the user can verify the version in **About** and that preferences and PHP installations remain intact.

The publisher refuses an existing tag to prevent overwriting signed release artifacts. If uploading fails, the release stays a draft: inspect the error and draft on GitHub before retrying or completing it. Do not replace an already published archive; fix issues in a new version with a higher build number. Normal commits and draft/prerelease releases do not automatically become application updates.

## Add a DMG to an existing release

For an already published version without a DMG, use the exact original release ZIP, not a newly compiled application. Keep the version in `Resources/Info.plist` at the release being supplemented. Download its ZIP into `build/releases/<version>/` and extract it to a separate directory:

```sh
mkdir -p build/dmg-source
ditto -x -k build/releases/1.6.0/PHP-Switcher-1.6.0-arm64.zip build/dmg-source
bash Scripts/create_dmg.sh 'build/dmg-source/PHP Switcher.app'
git push origin main
python3 Scripts/publish_release.py --add-dmg
```

Commit packaging changes before publishing. `--add-dmg` verifies that the local ZIP matches GitHub's digest for the original asset and that the DMG contains exactly the same application. It uploads only the new DMG and its `.dmg.sha256` checksum. The existing ZIP, signed feed, combined checksums, release tag, and application build number remain intact. The command refuses to overwrite an existing DMG or checksum; if an upload is interrupted, inspect the release assets before completing it.

## Update behavior

`SUEnableAutomaticChecks` defaults to enabled and `SUScheduledCheckInterval` is six hours. `AppUpdates.start()` also requests a startup check when enabled. Sparkle handles subsequent scheduling. The separate `automaticallyDownloadAppUpdates` preference defaults to enabled.

Sparkle's silent automatic installation path is disabled. The custom user driver starts downloads, shows progress in Settings, and retains the prepared-installation callback until **Install and restart** is clicked. The application delegates validation, extraction, replacement, and relaunch to Sparkle. Normal Quit cancels a pending download or prepared installation and waits for Sparkle's acknowledgement; quitting during extraction waits until cancellation is available. The install action also checks that no PHP operation or configuration editor is active.

The app requires signed feeds (`SURequireSignedFeed`) and verifies archives before extraction (`SUVerifyUpdateBeforeExtraction`). Sparkle system-profile submission is disabled. Update failures are shown separately from a successful up-to-date result.

Sparkle is pinned in `Scripts/fetch_sparkle.sh`, including its archive SHA-256. Update the pin and related test/publishing paths together when upgrading the framework. Its license and third-party notices are included in [Sparkle-LICENSE.txt](Sparkle-LICENSE.txt) and copied into the application bundle.
