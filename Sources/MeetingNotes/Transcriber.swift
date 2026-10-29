import Foundation

struct Segment: Codable, Hashable {
    var start: Double   // secondi
    var end: Double
    var text: String
    var speaker: String = ""
}

enum TranscribeError: LocalizedError {
    case missingTool(String)
    case missingModel(URL)
    case badResponse(String)
    var errorDescription: String? {
        switch self {
        case .missingTool(let t): return "\(t) non trovato: serve solo con whisper.cpp o le API (brew install ffmpeg). Con la trascrizione di macOS non serve."
        case .missingModel(let u): return "Modello Whisper non trovato in \(u.path). Lancia scripts/install-deps.sh."
        case .badResponse(let s): return "Risposta di trascrizione non valida: \(s.prefix(300))"
        }
    }
}

/// Trascrive una traccia. Motori: trascrizione di macOS (default, on-device), whisper.cpp in locale,
/// oppure Groq/OpenAI Whisper API se c'è una chiave nel .env.
struct Transcriber {
    let config: Config

    enum Engine: String { case apple, whisper, groq, openai }

    var engine: Engine {
        if let raw = config["TRANSCRIBE_PROVIDER"]?.lowercased() {
            if raw == "local" { return .whisper }
            if let forced = Engine(rawValue: raw) { return forced }
        }
        if config["GROQ_API_KEY"] != nil { return .groq }
        if config["OPENAI_API_KEY"] != nil { return .openai }
        return .apple
    }

    private var groqModel: String { config.string("GROQ_WHISPER_MODEL", default: "whisper-large-v3") }

    func label(for engine: Engine) -> String {
        switch engine {
        case .apple: return "macOS SpeechTranscriber (on-device)"
        case .whisper: return "whisper.cpp (\(config.whisperModel.deletingPathExtension().lastPathComponent))"
        case .groq: return "Groq \(groqModel)"
        case .openai: return "OpenAI whisper-1"
        }
    }

    /// Ritorna i segmenti e l'etichetta del motore effettivamente usato.
    func transcribe(_ audio: URL, workDir: URL) async throws -> ([Segment], String) {
        // ffmpeg serve solo a whisper.cpp e alle API; con la trascrizione di macOS basta AVFoundation.
        let ffmpeg = config.ffmpeg
        if ffmpeg == nil, engine != .apple { throw TranscribeError.missingTool("ffmpeg") }
        // Traccia muta (es. nessuno ha parlato al microfono): i modelli inventerebbero frasi, la saltiamo.
        if try await isSilent(audio, ffmpeg: ffmpeg) { return ([], label(for: engine)) }
        var used = engine
        let segments: [Segment]
        switch engine {
        case .apple:
            do {
                let lang = config.transcribeLanguage == "auto" ? config.notesLanguage : config.transcribeLanguage
                segments = Transcriber.groupWords(try await AppleSpeech.words(in: audio, language: lang))
            } catch {
                // Ripiego su whisper.cpp se è installato (es. lingua non supportata da Apple).
                guard let ffmpeg, config.whisperCLI != nil, FileManager.default.fileExists(atPath: config.whisperModel.path) else { throw error }
                NSLog("MeetingNotes: trascrizione Apple fallita (\(error.localizedDescription)), uso whisper.cpp")
                used = .whisper
                segments = try await transcribeLocal(audio, workDir: workDir, ffmpeg: ffmpeg)
            }
        case .whisper: segments = try await transcribeLocal(audio, workDir: workDir, ffmpeg: ffmpeg!)
        case .groq, .openai: segments = try await transcribeAPI(audio, workDir: workDir, ffmpeg: ffmpeg!)
        }
        return (segments.filter { !Transcriber.isHallucination($0.text) }, label(for: used))
    }

    // MARK: - Locale (whisper.cpp)

    private func transcribeLocal(_ audio: URL, workDir: URL, ffmpeg: String) async throws -> [Segment] {
        guard let whisper = config.whisperCLI else { throw TranscribeError.missingTool("whisper-cli") }
        guard FileManager.default.fileExists(atPath: config.whisperModel.path) else {
            throw TranscribeError.missingModel(config.whisperModel)
        }
        let base = workDir.appendingPathComponent(audio.deletingPathExtension().lastPathComponent)
        let wav = base.appendingPathExtension("wav")
        try await Shell.run(ffmpeg, ["-y", "-loglevel", "error", "-i", audio.path,
                                     "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav.path])
        // Timestamp per parola (-ml 1 -sow): i turni li ricostruiamo noi sulle pause, così mic e sistema
        // si intercalano correttamente. Il VAD (se il modello c'è) evita timestamp sballati sui silenzi lunghi.
        var args = ["-m", config.whisperModel.path, "-f", wav.path, "-l", config.transcribeLanguage,
                    "-oj", "-of", base.path, "-np", "-sns", "-ml", "1", "-sow"]
        if FileManager.default.fileExists(atPath: config.vadModel.path) {
            args += ["--vad", "-vm", config.vadModel.path]
        }
        try await Shell.run(whisper, args)
        let jsonURL = base.appendingPathExtension("json")
        let data = try Data(contentsOf: jsonURL)
        struct Out: Decodable {
            struct Item: Decodable {
                struct Offsets: Decodable { let from: Int; let to: Int }
                let offsets: Offsets
                let text: String
            }
            let transcription: [Item]
        }
        let out = try JSONDecoder().decode(Out.self, from: data)
        let words = out.transcription.map {
            Segment(start: Double($0.offsets.from) / 1000, end: Double($0.offsets.to) / 1000, text: $0.text)
        }
        return Transcriber.groupWords(words)
    }

    /// Raggruppa le parole in frasi: si chiude una frase a fine periodo (. ? !) o su una pausa > 0.8 s.
    /// whisper.cpp tende ad allungare l'ultima parola prima di un silenzio fino alla parola successiva:
    /// una parola che "dura" più di 1.5 s viene quindi accorciata e trattata come fine frase.
    static func groupWords(_ words: [Segment]) -> [Segment] {
        var segments: [Segment] = []
        var current: Segment?
        func close() {
            if let c = current {
                let t = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { segments.append(Segment(start: c.start, end: c.end, text: t)) }
            }
            current = nil
        }
        for w in words where !w.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if let c = current, w.start - c.end > 0.8 { close() }
            if current == nil { current = Segment(start: w.start, end: w.end, text: "") }
            current!.text += w.text
            let stretched = w.end - w.start > 1.5
            current!.end = stretched ? w.start + 0.8 : w.end
            let trimmed = w.text.trimmingCharacters(in: .whitespaces)
            if stretched || trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!") { close() }
        }
        close()
        return segments
    }

    // MARK: - API (Groq / OpenAI, endpoint compatibile)

    private func transcribeAPI(_ audio: URL, workDir: URL, ffmpeg: String) async throws -> [Segment] {
        let (endpoint, key, model): (String, String, String) = engine == .groq
            ? ("https://api.groq.com/openai/v1/audio/transcriptions", config["GROQ_API_KEY"] ?? "", groqModel)
            : ("https://api.openai.com/v1/audio/transcriptions", config["OPENAI_API_KEY"] ?? "", "whisper-1")

        // Blocchi da 10 minuti in mp3 mono: restano ben sotto il limite di 25 MB per richiesta.
        let chunkSeconds = 600.0
        let stem = audio.deletingPathExtension().lastPathComponent
        let pattern = workDir.appendingPathComponent("\(stem)-chunk%03d.mp3").path
        try await Shell.run(ffmpeg, ["-y", "-loglevel", "error", "-i", audio.path, "-ar", "16000", "-ac", "1",
                                     "-c:a", "libmp3lame", "-b:a", "48k", "-f", "segment",
                                     "-segment_time", String(Int(chunkSeconds)), "-reset_timestamps", "1", pattern])
        let chunks = try FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("\(stem)-chunk") && $0.pathExtension == "mp3" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var all: [Segment] = []
        for (i, chunk) in chunks.enumerated() {
            let offset = Double(i) * chunkSeconds
            let segs = try await postTranscription(chunk, endpoint: endpoint, key: key, model: model)
            all += segs.map { Segment(start: $0.start + offset, end: $0.end + offset, text: $0.text) }
        }
        return all
    }

    private func postTranscription(_ file: URL, endpoint: String, key: String, model: String) async throws -> [Segment] {
        let boundary = "mn-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        field("response_format", "verbose_json")
        field("temperature", "0")
        if config.transcribeLanguage != "auto" { field("language", config.transcribeLanguage) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: file))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw TranscribeError.badResponse(String(decoding: data, as: UTF8.self))
        }
        struct Out: Decodable {
            struct Seg: Decodable { let start: Double; let end: Double; let text: String }
            let segments: [Seg]?
            let text: String?
        }
        let out = try JSONDecoder().decode(Out.self, from: data)
        if let segs = out.segments {
            return segs.compactMap {
                let t = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : Segment(start: $0.start, end: $0.end, text: t)
            }
        }
        return [Segment(start: 0, end: 0, text: out.text ?? "")]
    }

    // MARK: - Utilità

    /// Picco sotto i -50 dB = traccia praticamente muta.
    private func isSilent(_ audio: URL, ffmpeg: String?) async throws -> Bool {
        guard let ffmpeg else { return try AudioTools.peakDB(audio) < -50 }
        let r = try await Shell.run(ffmpeg, ["-hide_banner", "-i", audio.path, "-af", "volumedetect", "-f", "null", "-"],
                                    check: false)
        guard let line = r.stderr.split(separator: "\n").first(where: { $0.contains("max_volume:") }) else { return true }
        let value = line.split(separator: ":").last?.replacingOccurrences(of: "dB", with: "")
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard let db = Double(value) else { return true } // "-inf"
        return db < -50
    }

    /// Frasi tipiche che Whisper "allucina" su silenzio o rumore.
    static func isHallucination(_ text: String) -> Bool {
        let t = text.lowercased()
        let patterns = ["amara.org", "sottotitoli creati dalla comunità", "sottotitoli a cura di", "qtss",
                        "subtitles by the amara", "thank you for watching", "grazie per la visione",
                        "[musica]", "[music]", "[blank_audio]", "(musica)"]
        if patterns.contains(where: t.contains) { return true }
        return t.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)).isEmpty
    }
}
