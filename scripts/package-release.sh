#!/usr/bin/env bash
# Crea dist/MeetingNotes.zip, l'app pronta da allegare a una release GitHub (la scarica install.sh).
#   scripts/package-release.sh
#   gh release create v1.0.0 dist/MeetingNotes.zip --title "Meeting Notes 1.0.0"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MN_PACKAGE_ONLY=1 scripts/build-app.sh
mkdir -p dist
rm -f dist/MeetingNotes.zip
ditto -c -k --norsrc --noextattr --noacl --keepParent build/MeetingNotes.app dist/MeetingNotes.zip
rm -rf build/MeetingNotes.app
echo "==> dist/MeetingNotes.zip ($(du -h dist/MeetingNotes.zip | cut -f1))"
