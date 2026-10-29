#!/usr/bin/env bash
# Installa le dipendenze di Meeting Notes.
#   scripts/install-deps.sh            → solo ffmpeg (basta con la trascrizione di macOS, default)
#   scripts/install-deps.sh --whisper  → anche whisper.cpp + modello "medium" + modello VAD (alternativa offline)
set -euo pipefail

MODEL_DIR="${HOME}/.local/share/meeting-notes/models"
MODEL_NAME="${WHISPER_MODEL_NAME:-ggml-medium.bin}"
VAD_NAME="ggml-silero-v5.1.2.bin"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew non trovato: installalo da https://brew.sh e rilancia." >&2
  exit 1
fi

download() { # $1=url $2=destinazione
  if [[ -s "$2" ]]; then echo "==> Già presente: $2"; return; fi
  echo "==> Scarico $(basename "$2")…"
  curl -L --fail --progress-bar -o "$2.part" "$1"
  mv "$2.part" "$2"
}

echo "==> brew install ffmpeg"
brew install ffmpeg

if [[ "${1:-}" == "--whisper" ]]; then
  echo "==> brew install whisper-cpp"
  brew install whisper-cpp
  mkdir -p "$MODEL_DIR"
  download "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_NAME}" "${MODEL_DIR}/${MODEL_NAME}"
  download "https://huggingface.co/ggml-org/whisper-vad/resolve/main/${VAD_NAME}" "${MODEL_DIR}/${VAD_NAME}"
fi

mkdir -p "${HOME}/.config/meeting-notes"
if [[ ! -f "${HOME}/.config/meeting-notes/.env" ]]; then
  cp "$(dirname "$0")/../.env.example" "${HOME}/.config/meeting-notes/.env"
  echo "==> Creato ~/.config/meeting-notes/.env (da .env.example)"
fi

echo "==> Fatto."
command -v claude >/dev/null 2>&1 \
  && echo "    claude CLI: $(command -v claude) (riepiloghi con il tuo abbonamento)" \
  || echo "    ! claude CLI non trovato: installa Claude Code ed esegui 'claude' una volta per il login."
