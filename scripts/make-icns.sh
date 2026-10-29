#!/usr/bin/env bash
# Rigenera Resources/AppIcon.icns dallo script dell'icona.
set -euo pipefail
cd "$(dirname "$0")/.."
swift scripts/make-icon.swift Resources/AppIcon-1024.png vetro >/dev/null
SET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d Resources/AppIcon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Resources/AppIcon.icns"
