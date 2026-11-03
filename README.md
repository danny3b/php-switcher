# PHP Switcher

A small native macOS application for switching the PHP version used in Terminal and installing releases from the PHP 8.3, 8.4, and 8.5 branches.

Created by **danny3b**. Repository: [danny3b/php-switcher](https://github.com/danny3b/php-switcher).

## Requirements

- macOS 14 or later on Apple Silicon.
- Apple Command Line Tools to build the application.
- Python 3, existing Homebrew build libraries, and a compatible PHP installation to build additional PHP releases.
- Rosetta when using Intel Homebrew installations on Apple Silicon.

The application bundles Sparkle for signed application updates. The build script downloads a pinned release and verifies its SHA-256 checksum. The PHP installer uses libraries already available on the machine; it does not provision a new Homebrew environment.

## Build and install

```sh
git clone https://github.com/danny3b/php-switcher.git
cd php-switcher
bash build.sh
```

The output is `build/PHP Switcher.app`, signed locally with an ad hoc signature. Copy the application to `~/Applications` and open it. Run it from its final location before enabling launch at login.

The bundled build script targets Apple Silicon. The current builds are ad hoc signed, without Apple Developer ID notarization; macOS may require approval when first opening a downloaded copy. Sparkle verifies updates with a separate Ed25519 release signature.

## Usage

Click **Use** to select a PHP version for subsequent `php` commands. You can also switch versions from the PHP menu in the macOS menu bar. **Install** downloads and builds the selected release. **Other version…** accepts an exact release number. Installing a release does not activate it automatically.

The default list includes PHP Switcher installations, manually added installations, and the active PHP version. **Show other installations** also reveals PHP discovered in MAMP and Homebrew. **Add from disk…** accepts an installation directory or a `bin/php` executable. The sliders button opens that installation's configuration editor.

After the initial shell path setup, open a new Terminal window. If a terminal already uses `~/.local/php/current/bin`, switching applies to its next PHP invocation. Selecting a CLI version does not switch Apache, PHP-FPM, or MAMP to that version.

The labels in this README use the English interface. Choose **English** in the app's language settings to use those labels.

## App settings and languages

The main window has **PHP versions**, **Settings**, and **About** tabs. Open settings with **⌘,**, the application menu, or the PHP menu in the menu bar.

- **App language:** Polish or English. The selection is saved automatically and takes effect immediately in the interface, PHP menu, configuration editor, and installer progress messages. Existing users retain Polish as the default. GitHub advisory content and external tool logs retain their source language.
- **Launch at startup:** opens PHP Switcher when the user logs in to macOS. The app uses `SMAppService.mainApp` and reads its actual system status, including after returning from System Settings. If macOS requires approval, the app displays a separate message and a button to open Login Items settings. A failed registration is not presented as enabled. The app does not register itself at login by default.
- **About:** shows the application name, version and build number from the bundle, a short description, and the creator, **danny3b**.

See Apple's [SMAppService documentation](https://developer.apple.com/documentation/servicemanagement/smappservice) for the login-item mechanism.

## Application updates

Open **Settings → App updates** to check manually, change automatic checks or downloads, and install a downloaded update. The application menu and PHP menu also include **Check for app updates…**.

- Checks run at startup and every six hours while the application is running, including when its window is closed to the menu bar. Sparkle manages scheduling and wake handling. Disable automatic checks to check only manually.
- New compatible stable releases download automatically by default. Turn this off to use **Download update** instead.
- **Install and restart** replaces the application and reopens it. PHP operations and an open configuration editor block this action until they finish or close. Normal application quit cancels a prepared installation instead of accepting it.
- Both the update feed and archive require Ed25519 signatures. Archives are verified before extraction. A failed download or validation leaves the installed application in place and displays an error.
- Updates come from the public [GitHub Releases page](https://github.com/danny3b/php-switcher/releases). No GitHub token is stored in the application. Checks do not upload PHP installation paths or project files, and Sparkle system-profile reporting is disabled.

Version 1.6.0 is the first version with an updater; earlier versions need this version installed manually once. A source commit alone does not publish an application update: maintainers must publish a signed release with its ZIP archive and `appcast.xml`. See [Releasing](Docs/Releasing.md).

## Removing PHP installations

The **Trash** button next to a PHP Switcher installation moves the entire installation, including its `php.ini` and extensions, to macOS Trash. The confirmation shows the exact version and path, with **Cancel** as the default action. The installation list and security assessment refresh afterward.

- An active PHP installation cannot be removed. Select another version with **Use** first.
- For manually added directories, the **minus** button only removes the list entry. Files stay on disk and can be added again with **Add from disk…**.
- Homebrew installations use **Uninstall through Homebrew**. The confirmation includes the version, formula, and path. `brew uninstall --formula` permanently uninstalls the selected package; files do not go to Trash. Automatic dependency removal, Homebrew updates, and cleanup are disabled. The app does not use `--force` or `--ignore-dependencies`, so Homebrew can protect packages required by other software. Intel Homebrew in `/usr/local` runs through Rosetta on Apple Silicon.
- Homebrew removal checks the Cellar path, installation receipt, symbolic links, and PHP-FPM service. Active PHP and multiple installed releases of the same formula block ambiguous removal. The state is checked again after confirmation.
- MAMP installations remain managed by MAMP. Clicking a removal button for a protected installation explains the reason.

To restore a trashed installation, move its folder back to the path shown in the confirmation, such as `~/.local/php/8.4.27`, then click **Refresh**. Do not overwrite a newer installation at that path. Disk space is reclaimed when the user empties Trash.

Removal, switching, and installation share a lock. Revalidation protects the active version and detects directory or version changes made after a confirmation opens. If moving an installation to Trash fails, the app reports the error rather than permanently deleting the files.

### Stopping PHP-FPM services

The **Stop** button beside a Homebrew installation opens a **Stop service** confirmation. It stops the current user's PHP-FPM service and disables that service's launch at login while keeping PHP installed. Clicking **Trash** for an installation with a service offers to stop it first, followed by a separate uninstall confirmation. Cancelling the second confirmation keeps PHP on disk.

The app checks the LaunchAgent file's owner, label, program, and identity, as well as the program used by the running service. It stops only the validated service through macOS `launchctl` and verifies the result. This also supports older PHP 7.3/7.4 services whose taps are not trusted by current Homebrew; it neither changes tap trust nor executes their formula code.

Inactive login entries can also be disabled. A copy of the LaunchAgent file is stored in `~/Library/Application Support/PHP Switcher/stopped-services/<identifier>/`. Administrator-managed system services are not changed by this action.

## Graphical php.ini editor

Click the **sliders** button beside an installation, edit its values, and choose **Save settings**. The editor has four categories:

| Category | Settings |
| --- | --- |
| File uploads | `file_uploads`, `upload_max_filesize`, `post_max_size`, `max_file_uploads` |
| Memory and limits | `memory_limit`, `max_execution_time`, `max_input_time`, `max_input_vars` |
| Errors and logs | `display_errors`, including `stderr`, `display_startup_errors`, `log_errors` |
| Date and time | `date.timezone`, with common time zone suggestions |

Enter sizes as byte counts or with `K`, `M`, or `G` suffixes, such as `128M`. The form validates values, warns when the POST limit is inconsistent with the upload limit, and blocks invalid changes. It displays time limits saved in configuration files because CLI execution overrides some of those limits at runtime.

The editor discovers the main `php.ini` and additional `.ini` files in the order loaded by the selected PHP executable. If an additional file overrides a setting, the change is written to that file and its name is shown in the form. Only selected fields are changed; other settings, comments, and conditional `PATH`/`HOST` sections are preserved. Missing global entries are added to the main file. Multiline values for edited fields must be changed in a text editor.

Before saving, each modified file is backed up alongside the original as `<file>.php-switcher-<UUID>.bak`. **Show backup** reveals the copies in Finder. The app then runs the selected PHP executable to verify the result. On failure, it restores the previous files. External changes made since the editor opened block saving; **Reload** reads the latest configuration. Writes require normal user permissions to both the file and its directory, without automatic privilege escalation.

**Close** prompts before discarding unsaved changes. The folder button reveals the main configuration file in Finder. New CLI invocations load saved settings immediately; a web server using the same file needs to be restarted. Selecting a CLI PHP version does not change MAMP's server version or configuration.

References: [PHP core directives](https://www.php.net/manual/en/ini.core.php) and [configuration file loading](https://www.php.net/manual/en/configuration.file.php).

## PHP installer

- Installs each release in `~/.local/php/<version>`; `~/.local/php/current` points to the active installation.
- Verifies the PHP source archive against the SHA-256 checksum from the official php.net API.
- Uses existing Homebrew libraries and Apple Command Line Tools without updating Homebrew or its packages.
- Selects the PHP build architecture from the existing base installation. Intel libraries can produce x86_64 PHP while the application itself runs natively on Apple Silicon.
- Keeps a separate `php.ini` and extension directory for each release. Imagick is built for the matching PHP ABI when enabled in the base configuration.
- Checks startup, required extensions, SQLite, PNG generation, Imagick, and actual JIT execution before marking an installation ready.
- Removes incomplete installations after cancellation or failure while preserving existing installations and the active selection.
- Keeps these releases separate from `brew upgrade` management.

The installer was developed for an existing local Homebrew environment. A new Mac needs the required libraries and Command Line Tools first. Additional PECL extensions other than Imagick are not migrated automatically and need separate setup.

## Security checks

**PHP security** checks the official php.net release catalog and public advisories from the `php/php-src` GitHub repository. **Check now** forces a refresh. **Details** includes the automatic-check preference, per-installation results, CVE identifiers, and advisory links.

- Automatic checks are enabled by default. They run at startup and every six hours while the app remains open, including after its window is closed to the menu bar. A result less than six hours old is reused. Wake events check whether a refresh is due; failed checks are retried after at least 15 minutes. Quitting the app stops checks.
- The scope includes PHP Switcher installations, manually added installations, and active Terminal PHP. Other MAMP and Homebrew installations are excluded unless selected as active. Web server configuration is outside this scope.
- **Critical** comes from the PHP team's advisory severity, not merely the existence of a newer release. Comparisons stay within the relevant PHP branch and include earlier fixes even when the latest release contains only ordinary changes.
- A critical fix produces a red message in the window and a warning indicator in the PHP menu. Users can open the advisory or install the latest PHP in the same branch. If that version is already installed, the app offers to activate it. Installation and switching require an explicit user action.
- Offline sources, API limits, unknown data formats, and unsupported versions are not presented as confirmation that PHP is up to date. The last successful result remains visible with its timestamp and stale status. This is a version-and-advisory check, not an audit of linked libraries, PECL extensions, or vendor patches in custom builds. Each advisory describes its exploitation conditions.
- Checks require no GitHub account. Requests go to php.net and api.github.com without sending installation paths or project files.

Sources: [PHP release catalog](https://www.php.net/releases/?json), [PHP security advisories](https://github.com/php/php-src/security/advisories), and [GitHub's advisory API](https://docs.github.com/en/rest/security-advisories/repository-advisories#list-repository-security-advisories).

## Local files

| Purpose | Location |
| --- | --- |
| Installed application | `~/Applications/PHP Switcher.app` |
| Build output | `build/PHP Switcher.app` |
| PHP installations and active symbolic link | `~/.local/php` |
| Manually added installation paths | `~/Library/Application Support/PHP Switcher/installations.json` |
| Installer logs | `~/Library/Logs/PHP Switcher` |
| Downloaded archives | `~/Library/Caches/PHP Switcher` |
| Last complete security result | `~/Library/Caches/PHP Switcher/security.json` |
| Shell PATH entry | `~/.zprofile` |

An existing `.zprofile` is backed up as `.zprofile.php-switcher-*.bak` before modification. The `appLanguage` preference uses macOS user defaults.

## Development

Use English by default for documentation, development instructions, code comments, file names, code identifiers, and commit messages. Keep user-facing translations in their intended languages. See [AGENTS.md](AGENTS.md) for project conventions.

| File | Responsibility |
| --- | --- |
| `Sources/Core.swift` | PHP discovery, switching, removal, and service management |
| `Sources/App.swift` | Main application state, PHP interface, and menu bar integration |
| `Sources/Configuration.swift` | Configuration parsing, validation, backups, and verified writes |
| `Sources/ConfigurationView.swift` | Graphical configuration editor |
| `Sources/Security.swift` | Release and advisory checks, assessment, and caching |
| `Sources/SecurityView.swift` | Security status and details |
| `Sources/Preferences.swift` | Saved preferences and launch-at-login management |
| `Sources/PreferencesView.swift` | Main tabs, app settings, and About view |
| `Sources/AppUpdates.swift` | Sparkle scheduling, download state, and explicit installation |
| `Sources/AppUpdateView.swift` | Application update controls and progress |
| `Sources/Localization.swift` | Language selection and string interpolation |
| `Resources/en.lproj/Localizable.strings` | English UI translations |
| `Resources/install_php.py` | PHP source installer |

The existing localization system uses Polish source strings as fallback keys. `{0}`, `{1}`, and subsequent numbered placeholders represent arguments that translations may reorder. Installation source identifiers and configuration category identifiers remain independent of the selected language. English documentation conventions do not change saved application language preferences.

### Automated tests

Run these commands from the repository root. `build.sh` creates the output and module-cache directories.

```sh
bash build.sh

xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache Sources/Localization.swift Sources/Preferences.swift Tests/PreferencesTests.swift -framework ServiceManagement -o build/preferences-tests
build/preferences-tests

xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache -F build/dependencies/Sparkle-2.10.1 -framework Sparkle -Xlinker -rpath -Xlinker "$PWD/build/dependencies/Sparkle-2.10.1" Sources/Localization.swift Sources/AppUpdates.swift Tests/AppUpdatesTests.swift -o build/app-update-tests
build/app-update-tests

python3 -m unittest discover -s Tests -p 'test_*.py' -v

xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache Sources/Localization.swift Sources/Core.swift Tests/CoreTests.swift -o build/core-tests
build/core-tests

xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache Sources/Localization.swift Sources/Core.swift Tests/RemovalTests.swift -o build/removal-tests
build/removal-tests

xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache Sources/Localization.swift Sources/Core.swift Tests/HomebrewRemovalTests.swift -o build/homebrew-removal-tests
build/homebrew-removal-tests

xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache Sources/Localization.swift Sources/Core.swift Sources/Configuration.swift Tests/ConfigurationTests.swift -o build/configuration-tests
build/configuration-tests

xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache Sources/Localization.swift Sources/Core.swift Sources/Security.swift Tests/SecurityTests.swift -o build/security-tests
build/security-tests
```

Tests use isolated temporary directories and do not switch the user's real PHP installation. Preference tests use a separate user-defaults suite and a simulated login-item manager. Removal tests cover recovery, active-version protection, directory boundaries, symbolic links, replacement races, Trash failures, and installer concurrency. Security tests cover version ranges, branch isolation, critical fixes, unsupported or unknown data, caching, pagination, and connection/API failures.

App update tests cover automatic and manual downloads, progress, persistence, explicit installation, restart blocking, cancellation before normal quit, and offline/incompatible-release handling. Release publishing validates archive metadata, checksums, signatures, and the source revision before uploading assets.

`Tests/Fixtures` contains selected fields from official responses retrieved on October 22, 2026, without advisory descriptions.

### Optional integration checks

Run the build and test compilation commands above before these checks.

```sh
# Move and restore only a temporary test directory through macOS Trash.
build/removal-tests --trash-integration

# Read real Homebrew installations without uninstalling them.
build/homebrew-removal-tests --live

# Read PHP 7.3/7.4 service configuration without stopping services.
build/homebrew-removal-tests --live-services

xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache Sources/Localization.swift Sources/Core.swift Tests/ServiceIntegrationTests.swift -o build/service-integration-tests
# Start and stop only the test's own sleep process under a php@99.99 label.
build/service-integration-tests --run

# Use a real PHP executable with isolated temporary configuration files.
build/configuration-tests --php "$HOME/.local/php/current/bin/php"

# Contact the real release and advisory sources.
build/security-tests --live
```
