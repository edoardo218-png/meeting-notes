# Meeting Notes

App per Mac che registra le tue call (la tua voce e quella degli altri), le trascrive sul Mac e ne ricava una nota con riepilogo, sezioni per argomento e prossimi passi, scritta da Claude con il tuo abbonamento.

- **Trascrizione sul Mac** con il motore vocale di macOS: l'audio non esce dal computer.
- **Riepilogo con Claude** tramite Claude Code e il tuo abbonamento Claude (Pro o Max), senza API key.
- **Note in Markdown** in una cartella a tua scelta, con l'audio accanto. Se usi Obsidian, puoi salvarle anche direttamente nel vault.
- Niente account da creare, niente cloud e niente telemetria.

## Requisiti

- Mac con chip Apple (M1 o successivi).
- macOS 26 o successivo.
- Un abbonamento Claude (Pro o Max) per i riassunti.

## Installazione

Apri il **Terminale** (Spotlight: ⌘ Spazio, scrivi "Terminale"), incolla questa riga e premi Invio:

```bash
curl -fsSL https://raw.githubusercontent.com/edoardo218-png/meeting-notes/main/install.sh | bash
```

Il comando:
1. scarica l'app in `~/Applications/MeetingNotes.app`;
2. installa [Claude Code](https://claude.com/claude-code), se non c'è già;
3. apre Meeting Notes.

**Solo la prima volta** collega Claude al tuo account. Nel Terminale scrivi `claude` e premi Invio, accedi con il tuo abbonamento Claude nel browser, poi scrivi `/exit`.

Per aggiornare l'app basta rilanciare lo stesso comando.

### Permessi

Alla prima registrazione macOS chiede questi permessi. Rispondi "Consenti".

| Permesso | A cosa serve |
|---|---|
| **Microfono** | La tua voce. |
| **Solo registrazione audio di sistema** | La voce degli altri partecipanti (l'audio di Meet, Zoom, Teams...). Lo schermo non viene mai registrato. |
| **Notifiche** | "Stai entrando in una call: registro?", "Nota pronta". |
| **Calendari** | Riempire titolo e partecipanti dall'evento in corso. Se non ti serve, rispondi "Non consentire". |
| **Controllo del browser** | Accorgersi quando apri il link di una call nel browser. |

Se la voce degli altri non viene registrata, apri Impostazioni di Sistema > Privacy e sicurezza > Registrazione schermo e audio di sistema e attiva MeetingNotes nella sezione "Solo registrazione audio di sistema".

La prima volta che trascrivi, macOS potrebbe scaricare il modello vocale della lingua. Succede una volta sola.

## Come si usa

- **Registrare**: icona a fumetto nella barra dei menu > Avvia registrazione, oppure ⌃⌥⌘R da qualunque app. Quando entri in una call (Meet, Zoom, Teams...) arriva anche una notifica con il pulsante "Registra".
- **Durante la call**: nel pannello puoi scrivere appunti, che Claude usa come guida per la nota. ⌘B segna il minuto attuale. Il pannello non compare nella condivisione schermo.
- **Fine**: quando esci dalla call la registrazione si ferma da sola. Dopo qualche minuto arriva la notifica "Nota pronta".
- **Archivio** (clic sull'icona nel Dock): per ogni call ci sono la nota, la trascrizione con l'audio sincronizzato (i minuti sono cliccabili) e "Chiedi a Claude", per esempio "scrivimi la mail di follow-up". "Chiedi a tutte le riunioni" fa domande su più call insieme.
- **Titolo e tipo** si cambiano dall'archivio: doppio clic sul titolo, menu sotto il titolo. Il riassunto non viene rifatto.

## Dove finiscono le note

Per ogni call ci sono due file:
- `AAAA-MM-GG-HHMM.md`: riepilogo in alto, trascrizione completa sotto;
- `AAAA-MM-GG-HHMM.m4a`: l'audio.

La cartella predefinita è `~/MeetingNotes`. Per cambiarla vai in **Impostazioni** (⌘,) > Dove salvare le note > Cartella delle note > Scegli...

L'audio più vecchio di 30 giorni va nel Cestino in automatico (nota e trascrizione restano). Si cambia in Impostazioni > Spazio.

### Con Obsidian (facoltativo)

Se usi Obsidian, in Impostazioni compare "Salva le note nel vault Obsidian". Con questa opzione la nota segue un template del vault e va nella cartella del cliente riconosciuto dalla call (`Clienti/<Agenzia>/<Cliente>/Chiamate/`). Se il cliente non si riconosce, la nota va in `Inbox/`. Questa struttura è pensata per un vault organizzato per clienti.

## Impostazioni di partenza

Al primo avvio l'app parte con queste impostazioni ([Resources/defaults.json](Resources/defaults.json)). Si cambiano tutte da Impostazioni.

- Aspetto chiaro.
- Riassunti con Claude Sonnet, tramite Claude Code.
- Trascrizione con il motore di macOS, in italiano. La lingua si cambia in Impostazioni.
- Note in una cartella (non in Obsidian).
- Audio cancellato dopo 30 giorni.
- Proposta di fermare la registrazione dopo 10 minuti di silenzio.
- Titolo e partecipanti presi dal calendario.

Le impostazioni stanno in `~/.config/meeting-notes/settings.json`. Le opzioni avanzate, come le API key per usare altri modelli, vanno in `~/.config/meeting-notes/.env` (vedi [.env.example](.env.example)).

## Se qualcosa non va

- **Nota senza riassunto**: di solito Claude Code non ha ancora fatto il login (vedi Installazione). Dall'archivio, ⋯ > "Rigenera la nota con Claude".
- **Nella trascrizione manca la voce degli altri**: controlla il permesso "Solo registrazione audio di sistema" (vedi Permessi).
- **Registrazioni non elaborate**: restano in `~/MeetingNotes/.recordings/`. Per rielaborarle: menu Archivio > "Rielabora registrazioni in sospeso".

## Disinstallare

Trascina `~/Applications/MeetingNotes.app` nel Cestino. Se vuoi, cancella anche `~/.config/meeting-notes` (le impostazioni) e `~/Library/Application Support/MeetingNotes` (l'archivio dell'app). Le note nella tua cartella restano.

## Per sviluppatori

Servono i Command Line Tools di Xcode (`xcode-select --install`); Xcode completo non serve.

```bash
scripts/build-app.sh          # compila e installa ~/Applications/MeetingNotes.app
scripts/package-release.sh    # crea dist/MeetingNotes.zip per una release GitHub
```

- **Motori alternativi**: whisper.cpp in locale (`scripts/install-deps.sh --whisper`), oppure le API Groq/OpenAI per la trascrizione e Anthropic/OpenAI/Groq/Ollama per i riassunti. Si configurano in `.env`. Queste opzioni richiedono ffmpeg (`brew install ffmpeg`); con il motore di macOS non serve.
- **Da terminale**:
  - `MeetingNotes --process <cartella|audio>` rielabora una registrazione;
  - `--rename <id> "Titolo"` e `--assign <id> "Cliente"` cambiano titolo e cliente;
  - `--delete <id> [--files]` elimina una riunione;
  - `--ask-all "domanda"` fa una domanda su tutte le riunioni.
- **Test senza toccare l'archivio vero**: `MEETINGS_STORE_DIR`, `NOTES_DIR` e `VAULT_PATH` puntano a cartelle temporanee. `scripts/make-test-recording.sh` crea una finta registrazione con la sintesi vocale.
