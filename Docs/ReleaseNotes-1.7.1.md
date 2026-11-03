# PHP Switcher 1.7.1

- Fix delays when switching between PHP versions, Settings, and About by reusing security assessment results.
- Recalculate findings when security data or monitored installations change, preserving critical-fix and stale-data warnings.
- Reuse compiled version-matching expressions and avoid unnecessary text formatting during rendering.
- Coalesce menu updates and avoid rebuilding an unchanged menu or redrawing unchanged login settings.

## Installation

Download [PHP-Switcher-1.7.1-arm64.dmg](https://github.com/danny3b/php-switcher/releases/download/v1.7.1/PHP-Switcher-1.7.1-arm64.dmg), open it, and drag **PHP Switcher.app** onto **Applications**. Eject the image and launch the application from Applications.

Existing version 1.6.0 or later users can open **Settings → App updates → Check for updates**, then choose **Install and restart** after the download finishes.

Requires macOS 14 or later on Apple Silicon. This build is ad hoc signed and is not Apple-notarized.
