#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SPARKLE_VERSION=2.10.1
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
SPARKLE_ROOT="$PWD/build/dependencies/Sparkle-$SPARKLE_VERSION"
SPARKLE_ARCHIVE="$SPARKLE_ROOT.tar.xz"
mkdir -p "$(dirname "$SPARKLE_ROOT")"
if [ ! -f "$SPARKLE_ARCHIVE" ]; then
  curl --fail --location --proto '=https' --tlsv1.2 --retry 2 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    -o "$SPARKLE_ARCHIVE.partial"
  mv "$SPARKLE_ARCHIVE.partial" "$SPARKLE_ARCHIVE"
fi
echo "$SPARKLE_SHA256  $SPARKLE_ARCHIVE" | shasum -a 256 -c - >&2
if [ ! -f "$SPARKLE_ROOT/.verified-$SPARKLE_SHA256" ]; then
  mkdir -p "$SPARKLE_ROOT"
  tar -xf "$SPARKLE_ARCHIVE" -C "$SPARKLE_ROOT"
  touch "$SPARKLE_ROOT/.verified-$SPARKLE_SHA256"
fi
printf '%s\n' "$SPARKLE_ROOT"
