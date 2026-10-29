import Foundation

/// Tipo di riunione: aggiunge sezioni specifiche al riepilogo.
enum NoteTemplate: String, Codable, CaseIterable, Identifiable {
    case generico
    case callCliente = "call-cliente"
    case conoscitiva
    case interna

    var id: String { rawValue }

    var label: String {
        switch self {
        case .generico: return "Generica"
        case .callCliente: return "Call cliente (operativa)"
        case .conoscitiva: return "Call conoscitiva / vendita"
        case .interna: return "Riunione interna"
        }
    }

    /// Sezioni extra (titolo → istruzione per l'LLM) dopo Riepilogo / Decisioni / Action item.
    var extraSections: [(String, String)] {
        switch self {
        case .generico, .interna:
            return []
        case .callCliente:
            return []   // i prossimi passi stanno già nei Next Steps del template
        case .conoscitiva:
            return [
                ("Bisogni e problemi emersi", "the client's needs, pains and goals as they described them, with short quotes where useful"),
                ("Obiezioni e dubbi", "objections, doubts, budget or timing constraints raised; if none, say so"),
            ]
        }
    }
}

/// Cliente del vault: `Clienti/<Agenzia>/<Nome>/` con l'hub `<Nome>.md`.
struct VaultClient: Codable, Hashable, Identifiable {
    var name: String
    var group: String
    /// Percorso relativo alla root del vault, es. "Clienti/Diretti/Acme".
    var folder: String
    var id: String { folder }
}

/// Dati della riunione scelti prima o durante la registrazione.
struct MeetingSetup: Codable, Equatable {
    var title: String = ""
    var client: VaultClient?
    var clientSource: String?          // "manuale" | "calendario" | "automatico"
    var participants: String = ""      // nomi separati da virgola
    var template: NoteTemplate = .generico
    var micDeviceID: String?           // nil = microfono di sistema
    var audioAppBundleID: String?      // nil = tutto l'audio di sistema
    var calendarEvent: String?

    var participantList: [String] {
        participants.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func resolvedTitle(at date: Date) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if let client { return "Call \(client.name)" }
        let f = DateFormatter()
        f.dateFormat = "HH.mm"
        return "Riunione delle \(f.string(from: date))"
    }
}

/// Esito del riconoscimento automatico del cliente (e delle persone nuove) dal contenuto della call.
struct ClientDetection: Codable, Hashable {
    struct Person: Codable, Hashable { var name: String; var role: String? }
    var client: String?
    var confidence: String?
    var evidence: String?
    var otherClients: [String]?
    var unknownCompany: String?
    var newPeople: [Person]?

    enum CodingKeys: String, CodingKey {
        case client, confidence, evidence
        case otherClients = "other_clients"
        case unknownCompany = "unknown_company"
        case newPeople = "new_people"
    }

    var isConfident: Bool { ["high", "medium"].contains(confidence?.lowercased() ?? "") }
}

/// Contenuto della nota post call scritto dall'LLM (compila i segnaposto del template del vault).
struct CallSummary: Codable, Hashable {
    struct Section: Codable, Hashable { var titolo: String; var punti: [String] }
    var titolo: String?
    var tipo: String?
    var tagArgomenti: [String]?
    var obiettivo: String?
    var partecipanti: [String]?
    var forFutureAgent: String?
    var summary: [String]?
    var sezioni: [Section]?
    var nextSteps: [String]?
    var decisioni: [String]?

    enum CodingKeys: String, CodingKey {
        case titolo, tipo, obiettivo, partecipanti, summary, sezioni, decisioni
        case tagArgomenti = "tag_argomenti"
        case forFutureAgent = "for_future_agent"
        case nextSteps = "next_steps"
    }

    /// Versione Markdown per l'archivio e per "Chiedi a Claude".
    var markdown: String {
        var out = "## Summary\n\n" + (summary ?? []).map { "- \($0)" }.joined(separator: "\n") + "\n"
        for s in sezioni ?? [] {
            out += "\n# \(s.titolo)\n\n" + s.punti.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if let n = nextSteps, !n.isEmpty { out += "\n# Next Steps\n\n" + n.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if let d = decisioni, !d.isEmpty { out += "\n## Decisioni\n\n" + d.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return out
    }
}

/// Una riunione elaborata: è ciò che l'archivio mostra e da cui si rigenera la nota.
struct Meeting: Codable, Identifiable, Hashable {
    var id: String                      // stamp YYYY-MM-DD-HHMM
    var title: String
    var date: Date
    var durationSeconds: Double
    var setup: MeetingSetup
    var notePath: String
    var audioPath: String
    var segments: [Segment]
    var myNotes: String
    var summaryMarkdown: String?
    var summaryProvider: String?
    var transcriptionEngine: String
    var inVault: Bool
    var detection: ClientDetection?
    var call: CallSummary?
    var transcriptPath: String?

    var noteURL: URL { URL(fileURLWithPath: notePath) }
    var audioURL: URL { URL(fileURLWithPath: audioPath) }
    var transcriptText: String { Merge.format(segments) }

    static func == (a: Meeting, b: Meeting) -> Bool {
        a.id == b.id && a.summaryMarkdown == b.summaryMarkdown && a.title == b.title
            && a.notePath == b.notePath && a.audioPath == b.audioPath && a.setup == b.setup
    }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Archivio locale delle riunioni: un JSON per riunione in ~/Library/Application Support/MeetingNotes/meetings/.
enum MeetingStore {
    static let dir: URL = {
        // MEETINGS_STORE_DIR: archivio separato (per i test, così non finiscono nell'archivio vero).
        if let custom = ProcessInfo.processInfo.environment["MEETINGS_STORE_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MeetingNotes/meetings", isDirectory: true)
    }()

    static func save(_ m: Meeting) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(m).write(to: dir.appendingPathComponent("\(m.id).json"), options: .atomic)
    }

    static func all() -> [Meeting] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(Meeting.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    static func delete(_ m: Meeting) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(m.id).json"))
    }
}
