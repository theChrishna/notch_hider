#!/bin/zsh
# Regenerates Resources/AppIcon.icns from Resources/AppIcon-source.jpg
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
swift scripts/make_icon.swift Resources/AppIcon-source.jpg "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
rm -rf "$TMP"
echo "Wrote Resources/AppIcon.icns"
