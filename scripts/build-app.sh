#!/usr/bin/env bash
# Compila e assembla MeetingNotes.app, la firma e la sposta in ~/Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MeetingNotes"
BUNDLE_ID="${MN_BUNDLE_ID:-com.edoardo.meetingnotes}"
DEST="${MN_INSTALL_DIR:-$HOME/Applications}"
# Facoltativo: un'identità di firma stabile (es. "Apple Development: …" o un certificato self-signed)
# evita di dover riconcedere i permessi a ogni rebuild. Default: firma ad-hoc.
SIGN_IDENTITY="${MN_SIGN_IDENTITY:--}"

cd "$ROOT"
echo "==> swift build -c release"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

APP="$ROOT/build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] || "$ROOT/scripts/make-icns.sh"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
sips -Z 256 "$ROOT/Resources/AppIcon-1024.png" --out "$APP/Contents/Resources/NotificationIcon.png" >/dev/null
# Impostazioni di partenza, usate solo al primo avvio (se ~/.config/meeting-notes/settings.json non esiste ancora).
cp "$ROOT/Resources/defaults.json" "$APP/Contents/Resources/defaults.json"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>Meeting Notes</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Meeting Notes registra il tuo microfono per trascrivere le riunioni in locale.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Meeting Notes trascrive le riunioni sul Mac con il riconoscimento vocale di macOS.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Meeting Notes legge l'evento in corso per precompilare titolo, partecipanti e cliente della riunione.</string>
  <key>NSAppleEventsUsageDescription</key><string>Meeting Notes legge l'indirizzo della scheda attiva del browser per accorgersi quando apri il link di una call (Meet, Zoom, Teams) e proporti di registrarla.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Meeting Notes registra l'audio di sistema (la voce degli altri partecipanti) per trascrivere le riunioni.</string>
</dict>
</plist>
PLIST

echo "==> codesign ($SIGN_IDENTITY)"
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"

# MN_PACKAGE_ONLY=1: lascia l'app in build/ senza installarla (la usa scripts/package-release.sh).
if [[ -n "${MN_PACKAGE_ONLY:-}" ]]; then
  echo "==> Pronta: $APP"
  exit 0
fi

mkdir -p "$DEST"
rm -rf "$DEST/$APP_NAME.app"
# Spostata (non copiata): una sola copia registrata nel sistema, altrimenti Dock e notifiche possono
# prendere l'icona dalla copia sbagliata.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
mv "$APP" "$DEST/"
# Registra di nuovo l'app nel sistema: aggiorna l'icona in Dock, Finder e notifiche.
"$LSREGISTER" -f "$DEST/$APP_NAME.app" >/dev/null 2>&1 || true
touch "$DEST/$APP_NAME.app"
echo "==> Installata: $DEST/$APP_NAME.app"
echo "    Avvio:        open \"$DEST/$APP_NAME.app\""
echo "    Rielabora:    \"$DEST/$APP_NAME.app/Contents/MacOS/$APP_NAME\" --process <cartella|audio>"
