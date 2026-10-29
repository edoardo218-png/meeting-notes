import Foundation

/// Configurazione: ~/.config/meeting-notes/.env, poi settings.json (scritto dalla finestra Impostazioni),
/// poi le variabili d'ambiente del processo.
struct Config {
    let values: [String: String]

    /// MN_CONFIG_DIR serve ai test (es. simulare il primo avvio senza toccare le impostazioni vere).
    static let configDir = ProcessInfo.processInfo.environment["MN_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/meeting-notes", isDirectory: true)
    static let envFile = configDir.appendingPathComponent(".env")
    static let settingsFile = configDir.appendingPathComponent("settings.json")

    static func load() -> Config {
        var values: [String: String] = [:]
        if let text = try? String(contentsOf: envFile, encoding: .utf8) {
            values = parseDotEnv(text)
        }
        for (k, v) in loadSettings() {
            if v.isEmpty { values.removeValue(forKey: k) } else { values[k] = v }
        }
        // Le variabili d'ambiente del processo hanno la precedenza (utile per i test da terminale).
        for (k, v) in ProcessInfo.processInfo.environment where !v.isEmpty {
            values[k] = v
        }
        return Config(values: values)
    }

    static func loadSettings() -> [String: String] {
        seedDefaultsIfNeeded()
        guard let data = try? Data(contentsOf: settingsFile),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    /// Primo avvio su un Mac nuovo: le impostazioni di partenza vengono da defaults.json dentro l'app
    /// (se c'è). Chi ha già un settings.json non viene toccato.
    private static func seedDefaultsIfNeeded() {
        guard !FileManager.default.fileExists(atPath: settingsFile.path),
              let preset = Bundle.main.url(forResource: "defaults", withExtension: "json"),
              let data = try? Data(contentsOf: preset),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        saveSettings(dict)
    }

    static func saveSettings(_ dict: [String: String]) {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(dict).write(to: settingsFile, options: .atomic)
    }

    static func parseDotEnv(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, let l = value.last, f == l, f == "\"" || f == "'" {
                value = String(value.dropFirst().dropLast())
            } else if let hash = value.range(of: " #") {
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            if !value.isEmpty { out[key] = value }
        }
        return out
    }

    subscript(_ key: String) -> String? { values[key] }

    func string(_ key: String, default def: String) -> String { values[key] ?? def }

    func bool(_ key: String, default def: Bool) -> Bool {
        guard let v = values[key]?.lowercased() else { return def }
        return ["1", "true", "yes", "si", "sì", "on"].contains(v)
    }

    func int(_ key: String, default def: Int) -> Int { values[key].flatMap(Int.init) ?? def }

    func path(_ key: String, default def: String) -> URL {
        URL(fileURLWithPath: Config.expandTilde(values[key] ?? def))
    }

    static func expandTilde(_ p: String) -> String { (p as NSString).expandingTildeInPath }

    // MARK: - Valori derivati

    var notesDir: URL { path("NOTES_DIR", default: "~/MeetingNotes") }
    var recordingsDir: URL { notesDir.appendingPathComponent(".recordings", isDirectory: true) }
    var whisperModel: URL { path("WHISPER_MODEL_PATH", default: "~/.local/share/meeting-notes/models/ggml-medium.bin") }
    var vadModel: URL { path("WHISPER_VAD_MODEL_PATH", default: "~/.local/share/meeting-notes/models/ggml-silero-v5.1.2.bin") }
    /// Lingua parlata: "auto" (solo whisper/API; con Apple si usa NOTES_LANGUAGE) oppure es. "it", "en".
    var transcribeLanguage: String { values["TRANSCRIBE_LANGUAGE"] ?? values["WHISPER_LANGUAGE"] ?? "auto" }
    var notesLanguage: String { string("NOTES_LANGUAGE", default: "it") }
    var myName: String { string("MY_NAME", default: "Io") }
    var othersName: String { string("OTHERS_NAME", default: "Altri") }
    /// Nome di chi registra nelle note (OWNER_NAME, altrimenti MY_NAME se è un nome vero, altrimenti il nome dell'utente macOS).
    var ownerName: String {
        if let o = values["OWNER_NAME"] { return o }
        if myName != "Io" { return myName }
        return NSFullUserName().components(separatedBy: " ").first.flatMap { $0.isEmpty ? nil : $0 } ?? "chi registra"
    }

    // MARK: Obsidian

    /// Vault esplicito (VAULT_PATH) oppure quello aperto per ultimo in Obsidian.
    var vaultRoot: URL? {
        if let p = values["VAULT_PATH"] { return URL(fileURLWithPath: Config.expandTilde(p), isDirectory: true) }
        return Config.detectedVaults().first
    }
    var saveToVault: Bool { vaultRoot != nil && bool("SAVE_TO_VAULT", default: true) }
    var vaultUnassignedFolder: String { string("VAULT_UNASSIGNED_FOLDER", default: "Inbox") }

    /// Vault registrati in Obsidian (obsidian.json), con quello aperto per primo.
    static func detectedVaults() -> [URL] {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else { return [] }
        return vaults.values
            .sorted { (($0["open"] as? Bool) ?? false) && !(($1["open"] as? Bool) ?? false) }
            .compactMap { ($0["path"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) } }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Binari

    var ffmpeg: String? { binary("FFMPEG_PATH", names: ["ffmpeg"]) }
    var whisperCLI: String? { binary("WHISPER_CLI_PATH", names: ["whisper-cli", "whisper-cpp"]) }
    var claudeCLI: String? { binary("CLAUDE_PATH", names: ["claude"]) }

    /// Le app avviate dal Finder non ereditano il PATH della shell: cerchiamo nei percorsi soliti.
    func binary(_ overrideKey: String, names: [String]) -> String? {
        let fm = FileManager.default
        if let p = values[overrideKey] {
            let e = Config.expandTilde(p)
            return fm.isExecutableFile(atPath: e) ? e : nil
        }
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/.claude/local", "/usr/bin"]
            .map(Config.expandTilde)
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            dirs += envPath.split(separator: ":").map(String.init)
        }
        for name in names {
            for dir in dirs {
                let candidate = (dir as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }
}
