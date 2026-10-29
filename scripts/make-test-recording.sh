#!/usr/bin/env bash
# Crea una finta registrazione (mic.caf + system.caf + meta.json) con la sintesi vocale di macOS,
# per provare la pipeline senza registrare davvero:
#   scripts/make-test-recording.sh /tmp/mn-test
#   ~/Applications/MeetingNotes.app/Contents/MacOS/MeetingNotes --process /tmp/mn-test/2026-01-01-0900
# Copione personalizzato: SCRIPT=copione.txt (righe "me|testo" o "other|testo").
# Il mic contiene anche un'eco a basso volume della voce "di sistema" (come parlando senza cuffie).
set -euo pipefail
OUT="${1:?Uso: $0 <cartella-di-output>}"
STAMP="2026-01-01-0900"
WORK="$(mktemp -d)"
REC="$OUT/$STAMP"
mkdir -p "$REC"

if [[ -n "${SCRIPT:-}" ]]; then cp "$SCRIPT" "$WORK/script.txt"; else
cat > "$WORK/script.txt" <<'TXT'
me|Ciao Giulia, partiamo dal lancio della campagna di novembre.
other|Ciao Marco. Ho guardato i numeri: il costo per lead su Meta è salito a undici euro.
me|Allora riduciamo il budget su Meta del venti per cento e spostiamo la quota su Google Search.
other|D'accordo. Io preparo tre nuove creatività statiche entro venerdì.
me|Perfetto. Io aggiorno le landing page e ti mando il report lunedì mattina.
other|Ok, decidiamo anche di sospendere la campagna video su TikTok fino a dicembre.
me|Sì, confermato. Ci sentiamo la prossima settimana.
TXT
fi

t=1.0; i=0
while IFS='|' read -r who text; do
  v=$([ "$who" = me ] && echo "Reed (Italiano (Italia))" || echo Alice)
  say -v "$v" -o "$WORK/$i.aiff" "$text"
  d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WORK/$i.aiff")
  echo "$i $who $t" >> "$WORK/timeline.txt"
  t=$(echo "$t + $d + 0.6" | bc); i=$((i+1))
done < "$WORK/script.txt"

build() { # $1=speaker principale  $2=file di output  $3=se non vuoto aggiunge l'eco dell'altro
  local args=() filt="" n=0 mix=""
  while read -r idx who start; do
    if [ "$who" != "$1" ] && [ -z "$3" ]; then continue; fi
    local vol=1; [ "$who" != "$1" ] && vol=0.2
    local ms; ms=$(echo "$start*1000/1" | bc)
    args+=(-i "$WORK/$idx.aiff")
    filt+="[$n:a]aresample=48000,volume=$vol,adelay=${ms}|${ms}[a$n];"; mix+="[a$n]"; n=$((n+1))
  done < "$WORK/timeline.txt"
  ffmpeg -y -loglevel error "${args[@]}" -filter_complex "${filt}${mix}amix=inputs=$n:normalize=0,apad=pad_dur=2[out]" \
    -map "[out]" -ac 1 -ar 48000 -c:a pcm_f32le "$2"
}
build me "$REC/mic.caf" echo
build other "$REC/system.caf" ""
echo '{"startedAt":"2026-01-01T08:00:00Z","durationSeconds":45,"micCaptured":true}' > "$REC/meta.json"
rm -rf "$WORK"
echo "$REC"
