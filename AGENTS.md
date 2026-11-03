# Project instructions

## Language and naming

- Use English by default for documentation, README files, development instructions, code comments, commit messages, and pull request titles and descriptions.
- Use English names for files, directories, variables, functions, types, and other code identifiers.
- Follow the existing naming style: Swift files and types use PascalCase, Swift members use camelCase, and Python modules and functions use snake_case.
- Keep supported user-facing translations in their intended languages. The documentation language does not change the user's selected application language. Preserve existing localization keys and persisted values when making unrelated changes.

## Project structure

- `Sources/` contains the native SwiftUI/AppKit application and PHP management services.
- `Resources/` contains bundle metadata, the application icon, localization resources, and the Python PHP installer.
- `Tests/` contains standalone Swift test executables, Python unit tests, and security API fixtures.
- `build.sh` builds and locally signs `build/PHP Switcher.app` for Apple Silicon and macOS 14 or later.
- See `README.md` for build commands, test commands, supported behavior, and installation paths.

## Development and verification

- Keep the application free of external Swift dependencies unless the task requires otherwise.
- Use `Sources/Localization.swift` and the localization catalog for user-facing text. Preserve numbered placeholders when updating translations.
- Keep installation source identifiers and configuration category identifiers independent of the selected UI language.
- Preserve the safeguards around active PHP installations, shared installer locks, configuration backups, Homebrew service ownership, and removal confirmations.
- Use isolated temporary directories and a simulated login-item manager for automated tests. Keep live integration checks separate from the default test workflow.
- Run `bash build.sh` for application changes and the relevant test commands from `README.md` for changed behavior.
- Leave the installed application untouched when building or publishing releases. The user tests the update channel and triggers installation themselves; install locally only when explicitly requested.
- Do not commit build output, Python bytecode, local logs, caches, or credentials.

## Repository

- The remote repository is `https://github.com/danny3b/php-switcher`.
- The primary branch is `main`.
