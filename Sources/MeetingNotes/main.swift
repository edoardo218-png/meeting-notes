import AppKit
import Foundation

// Modalità riga di comando: MeetingNotes --process <cartella-registrazione | file-audio>
let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--process") {
    guard i + 1 < arguments.count else {
        FileHandle.standardError.write("Uso: MeetingNotes --process <cartella-registrazione | file-audio>\n".data(using: .utf8)!)
        exit(2)
    }
    let input = URL(fileURLWithPath: Config.expandTilde(arguments[i + 1])).standardizedFileURL
    Task {
        do {
            let result = try await Pipeline(config: Config.load()).process(input) { msg in print("· \(msg)") }
            print("Nota:  \(result.meeting.notePath)")
            print("Audio: \(result.meeting.audioPath)")
            print("LLM:   \(result.meeting.summaryProvider ?? "nessuno")")
            result.warnings.forEach { print("! \($0)") }
            exit(0)
        } catch {
            FileHandle.standardError.write("Errore: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    dispatchMain()
}

// MeetingNotes --assign <id-riunione> "<Nome cliente>": assegna il cliente, sposta nota e audio, propaga nel vault.
if let i = arguments.firstIndex(of: "--assign"), i + 2 < arguments.count {
    let id = arguments[i + 1], name = arguments[i + 2]
    let config = Config.load()
    guard let meeting = MeetingStore.all().first(where: { $0.id == id }) else {
        FileHandle.standardError.write("Riunione \(id) non trovata nell'archivio.\n".data(using: .utf8)!)
        exit(1)
    }
    guard let client = config.vaultRoot.map(Vault.init(root:))?.clients()
            .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
        FileHandle.standardError.write("Cliente \"\(name)\" non trovato nel vault.\n".data(using: .utf8)!)
        exit(1)
    }
    Task {
        var updated = meeting
        updated.setup.client = client
        updated.setup.clientSource = "manuale"
        if updated.setup.template == .generico { updated.setup.template = .callCliente }
        let result = Pipeline(config: config).updateDetails(updated, previous: meeting)   // niente nuovo riassunto
        print("Nota:  \(result.meeting.notePath)")
        result.warnings.forEach { print("! \($0)") }
        exit(0)
    }
    dispatchMain()
}

// MeetingNotes --rename <id-riunione> "<Titolo>": rinomina nota, trascrizione e audio e i link nel vault, senza nuovo riassunto.
if let i = arguments.firstIndex(of: "--rename"), i + 2 < arguments.count {
    guard let meeting = MeetingStore.all().first(where: { $0.id == arguments[i + 1] }) else {
        FileHandle.standardError.write("Riunione \(arguments[i + 1]) non trovata nell'archivio.\n".data(using: .utf8)!)
        exit(1)
    }
    var updated = meeting
    updated.setup.title = arguments[i + 2]
    let result = Pipeline(config: Config.load()).updateDetails(updated, previous: meeting)
    print("Nota:  \(result.meeting.notePath)")
    result.warnings.forEach { print("! \($0)") }
    exit(0)
}

// MeetingNotes --delete <id-riunione> [--files]: toglie la riunione dall'archivio (con --files anche nota, trascrizione e audio, nel Cestino).
if let i = arguments.firstIndex(of: "--delete"), i + 1 < arguments.count {
    let id = arguments[i + 1]
    guard let meeting = MeetingStore.all().first(where: { $0.id == id }) else {
        FileHandle.standardError.write("Riunione \(id) non trovata nell'archivio.\n".data(using: .utf8)!)
        exit(1)
    }
    let warnings = Pipeline(config: Config.load()).delete(meeting, deleteFiles: arguments.contains("--files"))
    warnings.forEach { print("! \($0)") }
    print("Eliminata: \(meeting.title)")
    exit(0)
}

// MeetingNotes --ask-all "domanda": domanda su tutte le riunioni in archivio (le più recenti per prime).
if let i = arguments.firstIndex(of: "--ask-all"), i + 1 < arguments.count {
    let question = arguments[i + 1]
    let meetings = MeetingStore.all().filter { !$0.segments.isEmpty }
    Task {
        do {
            print(try await Summarizer(config: Config.load()).askAll(question: question, meetings: meetings))
            print("\nFonti: " + meetings.enumerated().map { "[\($0.offset + 1)] \($0.element.title)" }.joined(separator: " · "))
            exit(0)
        } catch {
            FileHandle.standardError.write("Errore: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    dispatchMain()
}

// MeetingNotes --cleanup-audio: esegue subito la pulizia dell'audio vecchio (secondo AUDIO_RETENTION_DAYS).
if arguments.contains("--cleanup-audio") {
    let r = AudioCleanup.run(config: Config.load())
    print("Audio nel Cestino: \(r.trashed.count) (\(r.freedBytes / 1_000_000) MB)")
    r.trashed.forEach { print("· \($0)") }
    r.errors.forEach { print("! \($0)") }
    exit(0)
}

// MeetingNotes --test-link <url> <titolo scheda>: mostra come viene riconosciuto un link (per i test).
if let i = arguments.firstIndex(of: "--test-link"), i + 2 < arguments.count {
    let service = MeetingLinkDetector.service(for: arguments[i + 1]) ?? "-"
    let title = MeetingLinkDetector.cleanTitle(arguments[i + 2], service: service) ?? "(nessun titolo)"
    print("\(service) | \(title)")
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
