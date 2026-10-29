import SwiftUI

/// Impostazioni: scrivono ~/.config/meeting-notes/settings.json (stesse chiavi del .env, che restano valide).
struct SettingsView: View {
    @ObservedObject var state: AppState
    @ViewState private var values: [String: String] = Config.loadSettings()
    @ViewState private var confirmClear = false
    private let base = Config.load().values   // .env + valori attuali, per mostrare i default effettivi

    var body: some View {
        Form {
            Section {
                Picker("Aspetto", selection: binding("APPEARANCE", "system")) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Mostra nel Dock", isOn: bool("SHOW_IN_DOCK", true))
            } header: {
                HStack(spacing: Theme.Space.s) {
                    BrandMark(size: 22)
                    Text("Meeting Notes").font(.headline)
                }
                .padding(.bottom, Theme.Space.xs)
            } footer: {
                Text("\"Sistema\" segue l'impostazione chiaro/scuro di macOS. Senza Dock l'app resta nella barra dei menu in alto.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Generale") {
                TextField("Il tuo nome nelle note", text: binding("OWNER_NAME", Config(values: [:]).ownerName))
                TextField("Etichetta del tuo microfono nel transcript", text: binding("MY_NAME", "Io"))
                TextField("Etichetta degli altri partecipanti", text: binding("OTHERS_NAME", "Altri"))
                Picker("Lingua delle note", selection: binding("NOTES_LANGUAGE", "it")) {
                    Text("Italiano").tag("it")
                    Text("English").tag("en")
                }
                Picker("Tipo di riunione predefinito", selection: binding("DEFAULT_TEMPLATE", "generico")) {
                    ForEach(NoteTemplate.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }

            Section {
                if hasVault {
                    Toggle("Salva le note nel vault Obsidian", isOn: bool("SAVE_TO_VAULT", true))
                }
                if savingToVault {
                    Picker("Vault", selection: binding("VAULT_PATH", Config.detectedVaults().first?.path ?? "")) {
                        ForEach(vaultChoices, id: \.self) { path in
                            Text((path as NSString).lastPathComponent).tag(path)
                        }
                    }
                    Button("Scegli un'altra cartella…") { chooseVault() }
                    Toggle("Riconosci il cliente dal contenuto della call", isOn: bool("AUTO_CLIENT", true))
                    Toggle("Crea le note persona per le persone nuove", isOn: bool("AUTO_PEOPLE", true))
                    TextField("Cartella per le riunioni senza cliente", text: binding("VAULT_UNASSIGNED_FOLDER", "Inbox"))
                    Toggle("Aggiorna hub del cliente, daily e log", isOn: bool("PROPAGATE", true))
                    Toggle("Aggiungi le decisioni a \"<Cliente> - Decisioni\"", isOn: bool("PROPAGATE_DECISIONS", true))
                } else {
                    LabeledContent("Cartella delle note") {
                        HStack(spacing: Theme.Space.s) {
                            Text(notesDirLabel).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button("Scegli…") { chooseNotesDir() }
                        }
                    }
                    Button("Apri la cartella delle note") {
                        let dir = mergedConfig.notesDir
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                }
            } header: {
                Text("Dove salvare le note")
            } footer: {
                Text(savingToVault
                     ? "Se non scegli il cliente, Claude lo riconosce dalla call. Con il cliente la nota va in Clienti/<Agenzia>/<Cliente>/Chiamate/ (audio e trascrizione in raw/); se non è riconoscibile va in Inbox/ da smistare."
                     : "Ogni riunione diventa un file Markdown (riepilogo in alto, trascrizione sotto) con l'audio accanto, nella cartella scelta.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Audio") {
                Picker("Microfono", selection: binding("MIC_DEVICE_ID", "")) {
                    Text("Predefinito di sistema").tag("")
                    ForEach(state.microphones) { Text($0.name).tag($0.id) }
                }
                Picker("Audio della call", selection: binding("AUDIO_SOURCE_APP", "")) {
                    Text("Tutto l'audio del Mac").tag("")
                    ForEach(state.audioApps) { Text("Solo \($0.name)").tag($0.id) }
                }
            }

            Section("Trascrizione") {
                Picker("Motore", selection: binding("TRANSCRIBE_PROVIDER", "")) {
                    Text("Automatico (macOS, o API se c'è una chiave)").tag("")
                    Text("macOS (on-device)").tag("apple")
                    Text("whisper.cpp (locale)").tag("whisper")
                    Text("Groq Whisper API").tag("groq")
                    Text("OpenAI Whisper API").tag("openai")
                }
                Picker("Lingua parlata", selection: binding("TRANSCRIBE_LANGUAGE", "auto")) {
                    Text("Come le note").tag("auto")
                    Text("Italiano").tag("it")
                    Text("English").tag("en")
                }
            }

            Section {
                Picker("Riepilogo con", selection: binding("LLM_PROVIDER", "")) {
                    Text("Automatico (Claude, poi API key)").tag("")
                    Text("Claude (abbonamento, CLI)").tag("claude")
                    Text("Anthropic API").tag("anthropic")
                    Text("OpenAI API").tag("openai")
                    Text("Groq API").tag("groq")
                    Text("Ollama (locale)").tag("ollama")
                    Text("Nessuno: solo transcript").tag("none")
                }
                Picker("Modello Claude", selection: binding("CLAUDE_MODEL", "sonnet")) {
                    Text("Sonnet (consigliato)").tag("sonnet")
                    Text("Opus (più accurato, più lento)").tag("opus")
                    Text("Haiku (più veloce)").tag("haiku")
                }
            } header: {
                Text("Riepilogo")
            } footer: {
                Text("Le API key si impostano in ~/.config/meeting-notes/.env.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if state.notificationsDenied {
                Section {
                    Banner(kind: .warning, text: "Le notifiche di Meeting Notes sono disattivate: senza, non arrivano le proposte \"Stai entrando in una call: registro?\" né l'avviso di nota pronta.")
                    Button("Apri le impostazioni delle notifiche") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!)
                    }
                }
            }

            Section {
                Picker("Cancella l'audio delle call", selection: binding("AUDIO_RETENTION_DAYS", "0")) {
                    Text("Mai").tag("0")
                    Text("Dopo 14 giorni").tag("14")
                    Text("Dopo 30 giorni").tag("30")
                    Text("Dopo 60 giorni").tag("60")
                    Text("Dopo 90 giorni").tag("90")
                }
            } header: {
                Text("Spazio")
            } footer: {
                Text("L'audio va nel Cestino (recuperabile finché non lo svuoti). Nota, trascrizione, statistiche e minuti restano; il player di quelle riunioni non avrà più l'audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Automazioni") {
                Toggle("Mostra la trascrizione dal vivo durante la registrazione", isOn: bool("LIVE_TRANSCRIPT", true))
                Toggle("Rileva le call e proponi di registrarle", isOn: bool("AUTO_DETECT_CALLS", true))
                Toggle("Ferma la registrazione quando esci dalla call", isOn: bool("AUTO_STOP", true))
                Toggle("Riconosci i link delle call nel browser (Meet, Zoom, Teams…)", isOn: bool("DETECT_MEETING_LINKS", true))
                Toggle("Precompila titolo e partecipanti dal calendario", isOn: bool("USE_CALENDAR", false))
                Toggle("Scorciatoia globale ⌃⌥⌘R per avviare/fermare", isOn: bool("HOTKEY", true))
                Stepper(value: intBinding("SILENCE_STOP_MIN", 5), in: 0...30) {
                    let n = Int(binding("SILENCE_STOP_MIN", "5").wrappedValue) ?? 5
                    Text(n == 0 ? "Avviso di silenzio: disattivato" : "Proponi lo stop dopo \(n) min di silenzio")
                }
            }

            Section {
                LabeledContent("Riunioni nell'archivio", value: "\(state.meetings.count)")
                Button("Apri l'archivio") { WindowManager.shared.showArchive() }
                Button("Svuota l'archivio dell'app…", role: .destructive) { confirmClear = true }
                    .disabled(state.meetings.isEmpty)
            } header: {
                Text("Archivio")
            } footer: {
                Text("Una singola riunione si elimina dall'archivio (⋯ → Elimina, clic destro o ⌫), scegliendo se togliere anche nota, trascrizione e audio dal vault. \"Svuota\" toglie solo le voci dall'app: le note nel vault restano.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Apri il file .env") {
                    if !FileManager.default.fileExists(atPath: Config.envFile.path) {
                        try? FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
                        try? "".write(to: Config.envFile, atomically: true, encoding: .utf8)
                    }
                    NSWorkspace.shared.open(Config.envFile)
                }
                Button("Apri la cartella delle registrazioni grezze") {
                    try? FileManager.default.createDirectory(at: state.config.recordingsDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(state.config.recordingsDir)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Svuotare l'archivio dell'app?", isPresented: $confirmClear) {
            Button("Svuota (le note nel vault restano)", role: .destructive) {
                state.meetings.forEach { state.delete($0, deleteFiles: false) }
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Verranno tolte \(state.meetings.count) riunioni dall'elenco dell'app. Note, trascrizioni e audio nel vault non vengono toccati.")
        }
        .frame(minWidth: 520, minHeight: 560)
        .task { await state.refreshDevices(); state.reloadMeetings() }
    }

    /// Impostazioni correnti (comprese quelle appena cambiate), per mostrare o nascondere le sezioni.
    private var mergedConfig: Config {
        Config(values: base.merging(values) { $1 }.filter { !$0.value.isEmpty })
    }
    private var hasVault: Bool { mergedConfig.vaultRoot != nil }
    private var savingToVault: Bool { mergedConfig.saveToVault }
    private var notesDirLabel: String { (mergedConfig.notesDir.path as NSString).abbreviatingWithTildeInPath }

    private func chooseNotesDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Usa questa cartella"
        panel.message = "Dove salvare note e audio delle riunioni"
        panel.directoryURL = mergedConfig.notesDir
        if panel.runModal() == .OK, let url = panel.url { set("NOTES_DIR", url.path) }
    }

    private var vaultChoices: [String] {
        var list = Config.detectedVaults().map(\.path)
        if let custom = values["VAULT_PATH"], !custom.isEmpty, !list.contains(custom) { list.append(custom) }
        return list.isEmpty ? [""] : list
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { set("VAULT_PATH", url.path) }
    }

    // MARK: Binding sulle chiavi

    private func current(_ key: String) -> String? { values[key] ?? base[key] }

    private func set(_ key: String, _ value: String) {
        values[key] = value
        Config.saveSettings(values)
        state.applySettings()
        if key == "VAULT_PATH" || key == "SAVE_TO_VAULT" { state.reloadVault() }
    }

    private func binding(_ key: String, _ def: String) -> Binding<String> {
        Binding(get: { current(key) ?? def }, set: { set(key, $0) })
    }

    private func bool(_ key: String, _ def: Bool) -> Binding<Bool> {
        Binding(get: { Config(values: current(key).map { [key: $0] } ?? [:]).bool(key, default: def) },
                set: { set(key, $0 ? "1" : "0") })
    }

    private func intBinding(_ key: String, _ def: Int) -> Binding<Int> {
        Binding(get: { Int(current(key) ?? "") ?? def }, set: { set(key, String($0)) })
    }
}
