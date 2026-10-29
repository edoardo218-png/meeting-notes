#!/usr/bin/env bash
# Installa (o aggiorna) Meeting Notes sul Mac:
#   curl -fsSL https://raw.githubusercontent.com/edoardo218-png/meeting-notes/main/install.sh | bash
# Scarica l'ultima versione da GitHub, la mette in ~/Applications, installa Claude Code se manca e apre l'app.
set -euo pipefail

REPO="edoardo218-png/meeting-notes"
DEST="$HOME/Applications"
APP="$DEST/MeetingNotes.app"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Meeting Notes richiede un Mac con chip Apple (M1 o successivi)." >&2
  exit 1
fi
major="$(sw_vers -productVersion | cut -d. -f1)"
if (( major < 26 )); then
  echo "Meeting Notes richiede macOS 26 o successivo (hai la $(sw_vers -productVersion))." >&2
  echo "Aggiorna da Impostazioni di Sistema > Generali > Aggiornamento software, poi rilancia questo comando." >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> Scarico Meeting Notes..."
curl -fL --progress-bar -o "$tmp/MeetingNotes.zip" "https://github.com/$REPO/releases/latest/download/MeetingNotes.zip"
ditto -x -k "$tmp/MeetingNotes.zip" "$tmp"

# Se è già aperta (aggiornamento) la chiudo prima di sostituirla.
osascript -e 'tell application id "com.edoardo.meetingnotes" to quit' >/dev/null 2>&1 || true
sleep 1
mkdir -p "$DEST"
rm -rf "$APP"
mv "$tmp/MeetingNotes.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "==> Installata in $APP"

# Claude Code scrive i riassunti con il tuo abbonamento Claude (niente API key).
claude_bin=""
for c in "$HOME/.local/bin/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude" "$HOME/.claude/local/claude"; do
  [[ -x "$c" ]] && { claude_bin="$c"; break; }
done
if [[ -z "$claude_bin" ]]; then
  echo "==> Installo Claude Code (serve per i riassunti)..."
  curl -fsSL https://claude.ai/install.sh | bash
  claude_bin="$HOME/.local/bin/claude"
fi

open "$APP"

cat <<MSG

Fatto. Meeting Notes è aperta: la trovi nella barra dei menu in alto (icona a fumetto) e nel Dock.

Ultimo passaggio, solo la prima volta: collega Claude al tuo account.
  1. Qui nel Terminale scrivi:  $claude_bin
  2. Premi Invio, scegli l'accesso con il tuo abbonamento Claude e completa il login nel browser.
  3. Quando vedi il prompt di Claude, scrivi /exit e premi Invio.

MSG
