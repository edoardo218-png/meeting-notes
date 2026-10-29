import Foundation

/// stop → mix audio → trascrizione per traccia → merge Io/Altri → riconoscimento del cliente → nota post call
/// dal template del vault (+ trascrizione e audio in raw/) → propagazione secondo `_CLAUDE.md` → archivio.
struct Pipeline {
    let config: Config

    struct Result {
        let meeting: Meeting
        let warnings: [String]
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f
    }()

    /// Nome libero (YYYY-MM-DD-HHMM, con suffisso -2, -3… se già usato) per una nuova registrazione.
    static func freshStamp(for date: Date, config: Config) -> String {
        let base = stampFormatter.string(from: date)
        var stamp = base, n = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: config.recordingsDir.appendingPathComponent(stamp).path)
                || fm.fileExists(atPath: MeetingStore.dir.appendingPathComponent("\(stamp).json").path)
                || fm.fileExists(atPath: config.notesDir.appendingPathComponent("\(stamp).md").path) {
            stamp = "\(base)-\(n)"; n += 1
        }
        return stamp
    }

    private var vault: Vault? { config.saveToVault ? config.vaultRoot.map(Vault.init(root:)) : nil }
    private let inboxLabel = "Da smistare"

    // MARK: - Elaborazione di una registrazione

    /// `input` è una cartella di registrazione (system.caf + mic.caf + meta.json + notes.md) oppure un file audio singolo.
    func process(_ input: URL, progress: @escaping (String) -> Void = { _ in }) async throws -> Result {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: input.path, isDirectory: &isDir) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: input.path])
        }
        let isRecordingFolder = isDir.boolValue

        // Tracce, metadati e appunti
        var systemTrack: URL?, micTrack: URL?, singleTrack: URL?
        var meta: RecordingMeta?
        var myNotes = ""
        let stamp: String
        if isRecordingFolder {
            let s = input.appendingPathComponent("system.caf"), m = input.appendingPathComponent("mic.caf")
            systemTrack = fm.fileExists(atPath: s.path) ? s : nil
            micTrack = fm.fileExists(atPath: m.path) ? m : nil
            if let data = try? Data(contentsOf: input.appendingPathComponent("meta.json")) {
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                meta = try? dec.decode(RecordingMeta.self, from: data)
            }
            myNotes = (try? String(contentsOf: input.appendingPathComponent("notes.md"), encoding: .utf8)) ?? ""
            stamp = input.lastPathComponent
        } else {
            singleTrack = input
            let created = (try? fm.attributesOfItem(atPath: input.path)[.creationDate] as? Date) ?? Date()
            stamp = Pipeline.freshStamp(for: created, config: config)
        }
        let startedAt = meta?.startedAt ?? Pipeline.stampFormatter.date(from: String(stamp.prefix(15))) ?? Date()
        // Rielaborazione di una registrazione già salvata (es. il riepilogo era fallito): si riusano nota e percorsi,
        // senza creare un doppione né ripetere la propagazione nel vault.
        let existing = isRecordingFolder ? MeetingStore.all().first(where: { $0.id == stamp }) : nil
        var setup = existing?.setup ?? meta?.setup ?? MeetingSetup()
        if setup.client != nil, setup.clientSource == nil { setup.clientSource = "manuale" }

        let work = fm.temporaryDirectory.appendingPathComponent("meetingnotes-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. Audio mixato (in una cartella temporanea: la destinazione dipende da cliente e titolo)
        progress("Preparo l'audio…")
        let mixed = work.appendingPathComponent("mixed.m4a")
        let sources = [systemTrack, micTrack, singleTrack].compactMap { $0 }
        if let ffmpeg = config.ffmpeg {
            var args = ["-y", "-loglevel", "error"]
            for s in sources { args += ["-i", s.path] }
            if sources.count > 1 {
                args += ["-filter_complex", "amix=inputs=\(sources.count):duration=longest:normalize=0"]
            }
            args += ["-ac", "1", "-c:a", "aac", "-b:a", "96k", mixed.path]
            try await Shell.run(ffmpeg, args)
        } else {
            try AudioTools.mix(sources, to: mixed)   // senza Homebrew: AVFoundation
        }

        // 2. Trascrizione
        let transcriber = Transcriber(config: config)
        var segments: [Segment] = []
        var engines = Set<String>()
        if let singleTrack {
            progress("Trascrivo…")
            let (segs, used) = try await transcriber.transcribe(singleTrack, workDir: work)
            segments = segs
            engines.insert(used)
        } else {
            var mic: [Segment] = [], system: [Segment] = []
            if let micTrack {
                progress("Trascrivo il microfono…")
                let (segs, used) = try await transcriber.transcribe(micTrack, workDir: work)
                mic = segs
                engines.insert(used)
            }
            if let systemTrack {
                progress("Trascrivo l'audio della call…")
                let (segs, used) = try await transcriber.transcribe(systemTrack, workDir: work)
                system = segs
                engines.insert(used)
            }
            segments = Merge.merge(mic: mic, system: system, myName: config.myName, othersName: config.othersName)
        }

        // 3. Di che cliente si parla? (il cliente scelto da te ha sempre la precedenza)
        var detection: ClientDetection?
        if let vault, !segments.isEmpty, config.bool("AUTO_CLIENT", default: true) {
            progress("Riconosco il cliente…")
            let catalog = vault.clientCatalog()
            detection = await Summarizer(config: config).detectClient(
                transcript: Merge.format(segments), title: setup.title, participants: setup.participantList,
                myNotes: myNotes, catalog: catalog, knownPeople: vault.allPeople())
            if setup.client == nil, let d = detection, d.isConfident,
               let found = catalog.first(where: { $0.client.name.caseInsensitiveCompare(d.client ?? "") == .orderedSame }) {
                setup.client = found.client
                setup.clientSource = "automatico"
                if setup.template == .generico { setup.template = .callCliente }
            }
        }

        var meeting = Meeting(
            id: stamp, title: setup.resolvedTitle(at: startedAt), date: startedAt,
            durationSeconds: meta?.durationSeconds ?? segments.map(\.end).max() ?? 0,
            setup: setup, notePath: "", audioPath: "",
            segments: segments, myNotes: myNotes, summaryMarkdown: nil, summaryProvider: nil,
            transcriptionEngine: engines.sorted().joined(separator: " + "), inVault: vault != nil,
            detection: detection)

        // 4. Persone nuove previste (i nomi servono già al riepilogo per diventare wikilink)
        var plannedPeople: [(name: String, role: String)] = []
        if let vault, let client = setup.client {
            plannedPeople = plannedNewPeople(detection?.newPeople ?? [], client: client, vault: vault)
        }

        // 5. Contenuto della nota
        var warnings = await summarize(&meeting, extraLinkable: plannedPeople.map(\.name), progress: progress)

        // 6. Destinazione: titolo definitivo → nomi file
        if let existing, fm.fileExists(atPath: existing.notePath) {
            meeting.notePath = existing.notePath
            meeting.transcriptPath = existing.transcriptPath
            meeting.audioPath = existing.audioPath
            meeting.title = existing.title
        } else if let vault {
            let paths = vaultPaths(for: meeting, vault: vault)
            meeting.notePath = paths.note.path
            meeting.transcriptPath = paths.transcript.path
            meeting.audioPath = paths.audio.path
        } else {
            meeting.notePath = config.notesDir.appendingPathComponent("\(stamp).md").path
            meeting.audioPath = config.notesDir.appendingPathComponent("\(stamp).m4a").path
        }
        try fm.createDirectory(at: meeting.audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: meeting.audioPath) { try fm.removeItem(at: meeting.audioURL) }
        try fm.moveItem(at: mixed, to: meeting.audioURL)

        // 7. Persone nuove → stub in Persone/
        var newPeople: [String] = []
        if existing == nil, let vault, let client = setup.client {
            let noteName = meeting.noteURL.deletingPathExtension().lastPathComponent
            for p in plannedPeople {
                if (try? vault.createPersonStub(name: p.name, role: p.role, client: client, date: startedAt, sourceNote: noteName)) != nil {
                    newPeople.append(p.name)
                }
            }
        }

        // 8. Note, propagazione, archivio
        if let existing {
            warnings += write(&meeting, newPeople: [], propagate: false)
            if existing.call == nil, let vault, meeting.inVault { warnings += propagateDecisions(meeting, vault: vault) }
        } else {
            warnings += write(&meeting, newPeople: newPeople, propagate: true)
        }

        // Le tracce grezze si tengono finché il riepilogo non è riuscito (per poter rielaborare con le etichette).
        if isRecordingFolder && (meeting.call != nil || segments.isEmpty) {
            try? fm.removeItem(at: input)
        }
        return Result(meeting: meeting, warnings: warnings)
    }

    /// Rigenera la nota di una riunione in archivio. Se è cambiato il cliente (es. smistamento dall'Inbox)
    /// rinomina e sposta nota, trascrizione e audio, aggiorna i link già scritti e propaga al nuovo cliente.
    func regenerate(_ m: Meeting, previous: Meeting? = nil, progress: @escaping (String) -> Void = { _ in }) async -> Result {
        var meeting = m
        var warnings: [String] = []
        if previous == nil { relocate(&meeting) }   // nota spostata nel vault: si riscrive lì, non al vecchio posto
        let clientChanged = previous.map { $0.setup.client != m.setup.client } ?? false
        if clientChanged, m.setup.title.trimmingCharacters(in: .whitespaces).isEmpty, let previous {
            meeting.setup.title = previous.title   // il titolo resta quello già scelto
        }
        if clientChanged { meeting.setup.clientSource = "manuale" }
        warnings += await summarize(&meeting, extraLinkable: [], progress: progress)

        var moved = false
        if clientChanged, meeting.inVault, let vault {
            do {
                try move(&meeting, from: previous, vault: vault)
                moved = true
            } catch {
                warnings.append("Spostamento nel vault: \(error.localizedDescription)")
            }
        }
        warnings += write(&meeting, newPeople: [], propagate: moved)
        // Primo riepilogo riuscito dopo un fallimento: le decisioni non erano ancora nel registro del cliente.
        if !moved, previous?.call == nil, meeting.call != nil, meeting.inVault, let vault {
            warnings += propagateDecisions(meeting, vault: vault)
        }
        return Result(meeting: meeting, warnings: warnings)
    }

    /// Cambio di titolo, cliente o tipo dall'archivio: **nessun nuovo riassunto** e la nota nel vault non viene
    /// riscritta (restano le modifiche fatte in Obsidian). Se serve rinomina/sposta nota, trascrizione e audio,
    /// aggiorna i link in tutto il vault e, se cambia il cliente, i campi del cliente nel frontmatter.
    func updateDetails(_ m: Meeting, previous stale: Meeting) -> Result {
        var previous = stale
        var meeting = m
        var warnings: [String] = []
        // Nel frattempo la nota è stata spostata nel vault: si parte da dove è adesso.
        if relocate(&previous) {
            meeting.notePath = previous.notePath
            meeting.transcriptPath = previous.transcriptPath
            meeting.audioPath = previous.audioPath
            if m.setup.client == stale.setup.client {
                meeting.setup.client = previous.setup.client
                meeting.setup.clientSource = previous.setup.clientSource
            }
        }
        let clientChanged = previous.setup.client != meeting.setup.client
        if clientChanged { meeting.setup.clientSource = "manuale" }
        let typed = m.setup.title.trimmingCharacters(in: .whitespaces)
        meeting.title = typed.isEmpty ? previous.title : typed
        meeting.setup.title = meeting.title
        let titleChanged = meeting.title != previous.title

        var moved = false
        if meeting.inVault, let vault, clientChanged || titleChanged {
            do {
                try move(&meeting, from: clientChanged ? previous : nil, vault: vault)
                moved = clientChanged
            } catch {
                warnings.append("Spostamento nel vault: \(error.localizedDescription)")
            }
        }
        guard meeting.inVault, let vault, FileManager.default.fileExists(atPath: meeting.notePath) else {
            // Nota sparita (o fuori dal vault): la si riscrive dal riassunto già fatto.
            warnings += write(&meeting, newPeople: [], propagate: moved)
            return Result(meeting: meeting, warnings: warnings)
        }
        if clientChanged { warnings += patchClient(meeting, previous: previous, vault: vault) }
        if moved, config.bool("PROPAGATE", default: true) {
            do { try propagate(meeting, newPeople: [], vault: vault) } catch {
                warnings.append("Propagazione nel vault: \(error.localizedDescription)")
            }
        }
        do { try MeetingStore.save(meeting) } catch { warnings.append("Archivio: \(error.localizedDescription)") }
        return Result(meeting: meeting, warnings: warnings)
    }

    /// Note spostate nel vault da Obsidian o da un agent dopo la registrazione: aggiorna i percorsi (e il cliente,
    /// se ora stanno nella cartella di un cliente) invece di ricreare i file al vecchio posto.
    @discardableResult
    func relocate(_ m: inout Meeting) -> Bool {
        let fm = FileManager.default
        guard m.inVault, let vault, !fm.fileExists(atPath: m.notePath), let note = vault.locateMoved(m.notePath) else { return false }
        m.notePath = note.path
        if let t = m.transcriptPath, !fm.fileExists(atPath: t), let found = vault.locateMoved(t) { m.transcriptPath = found.path }
        if !fm.fileExists(atPath: m.audioPath), let found = vault.locateMoved(m.audioPath) { m.audioPath = found.path }
        let owner = vault.owner(of: note)
        if owner != m.setup.client {
            m.setup.client = owner
            m.setup.clientSource = owner == nil ? nil : "manuale"
        }
        return true
    }

    /// Cliente cambiato su una nota già scritta: aggiorna solo cliente, partner, stato, collegata_a e il tag del
    /// cliente (più la frase "da smistare" o "riconosciuto automaticamente" del preambolo). Il resto non si tocca.
    private func patchClient(_ m: Meeting, previous: Meeting, vault: Vault) -> [String] {
        let renderer = CallNoteRenderer(config: config, vault: vault)
        let oldTag = previous.setup.client.map { Vault.tagSlug($0.name) } ?? "da-smistare"
        let newTag = m.setup.client.map { Vault.tagSlug($0.name) } ?? "da-smistare"
        let today = Vault.dayFormatter.string(from: Date())
        do {
            var text = try String(contentsOf: m.noteURL, encoding: .utf8)
            text = Vault.replacingFrontmatter(["cliente", "partner", "stato", "collegata_a"], in: text,
                                              from: renderer.renderNote(m, newPeople: []))
            text = Vault.replacingTag(oldTag, with: newTag, in: text)
            text = text.replacingOccurrences(of: #"(?m)^updated: .*$"#, with: "updated: \(today)", options: .regularExpression)
            let assigned = m.setup.client.map { " Cliente assegnato a mano: [[\($0.name)]]." } ?? " Cliente tolto a mano: nota da smistare."
            for pattern in [#" Cliente non riconosciuto[^\n]*?nota da smistare nello spazio del cliente giusto\."#,
                            #" Il cliente \[\[[^\]]+\]\] è stato riconosciuto automaticamente[^\n]*?\[Inferito\]\."#,
                            #" Cliente assegnato a mano: \[\[[^\]]+\]\]\."#, #" Cliente tolto a mano: nota da smistare\."#] {
                if let r = text.range(of: pattern, options: .regularExpression) { text.replaceSubrange(r, with: assigned); break }
            }
            try text.write(to: m.noteURL, atomically: true, encoding: .utf8)
            if let t = m.transcriptPath, var raw = try? String(contentsOf: URL(fileURLWithPath: t), encoding: .utf8) {
                let field = m.setup.client.map { "cliente: \"[[\($0.name)]]\"" } ?? "cliente: TBD"
                raw = raw.replacingOccurrences(of: #"(?m)^cliente: .*$"#, with: field, options: .regularExpression)
                try raw.write(to: URL(fileURLWithPath: t), atomically: true, encoding: .utf8)
            }
            return []
        } catch {
            return ["Aggiornamento del cliente nella nota: \(error.localizedDescription)"]
        }
    }

    private func propagateDecisions(_ m: Meeting, vault: Vault) -> [String] {
        guard let client = m.setup.client, config.bool("PROPAGATE_DECISIONS", default: true) else { return [] }
        let decisions = (m.call?.decisioni ?? []).map { Vault.asciiSafe(Timestamps.strip($0)) }.filter { !$0.isEmpty }
        guard !decisions.isEmpty else { return [] }
        do {
            let file = try vault.appendDecisions(client: client, date: m.date, title: m.title,
                                                 noteName: m.noteURL.deletingPathExtension().lastPathComponent, decisions: decisions)
            try vault.appendLog(date: Date(), entries: ["update | [[\((vault.relativePath(file) as NSString).deletingPathExtension)]] appended"])
            return []
        } catch {
            return ["Decisioni: \(error.localizedDescription)"]
        }
    }

    // MARK: - Eliminazione

    /// Toglie la riunione dall'archivio dell'app. Con `deleteFiles` sposta nel Cestino nota, trascrizione e audio
    /// e rimuove le righe che l'app aveva aggiunto a index, hub del cliente e daily (le decisioni restano).
    func delete(_ m: Meeting, deleteFiles: Bool) -> [String] {
        var warnings: [String] = []
        if deleteFiles {
            let fm = FileManager.default
            for url in [m.noteURL, m.transcriptPath.map(URL.init(fileURLWithPath:)), m.audioURL].compactMap({ $0 })
            where fm.fileExists(atPath: url.path) {
                do { try fm.trashItem(at: url, resultingItemURL: nil) } catch {
                    warnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            // Cartella audio/ rimasta vuota: via anche lei.
            let audioDir = m.audioURL.deletingLastPathComponent()
            if audioDir.lastPathComponent == "audio",
               (try? fm.contentsOfDirectory(atPath: audioDir.path))?.filter({ !$0.hasPrefix(".") }).isEmpty == true {
                try? fm.removeItem(at: audioDir)
            }
            // Solo se la nota sta davvero in questo vault (non in un altro, es. uno di prova).
            if m.inVault, let vault = config.vaultRoot.map(Vault.init(root:)),
               m.noteURL.standardizedFileURL.path.hasPrefix(vault.root.standardizedFileURL.path + "/") {
                let link = "[[\(m.noteURL.deletingPathExtension().lastPathComponent)]]"
                var files = [vault.root.appendingPathComponent("index.md"),
                             vault.root.appendingPathComponent("Daily/\(Vault.dayFormatter.string(from: m.date)).md")]
                if let c = m.setup.client { files.append(vault.hubURL(c)) }
                for f in files { try? vault.removeListLines(in: f, containing: link) }
                try? vault.appendLog(date: Date(), entries: [
                    "delete | \(m.noteURL.deletingPathExtension().lastPathComponent) (nel Cestino, dall'app Meeting Notes)",
                ])
            }
        }
        let raw = config.recordingsDir.appendingPathComponent(m.id, isDirectory: true)
        if FileManager.default.fileExists(atPath: raw.path) { try? FileManager.default.trashItem(at: raw, resultingItemURL: nil) }
        MeetingStore.delete(m)
        return warnings
    }

    // MARK: - Riepilogo (LLM)

    private func linkableNames(for meeting: Meeting) -> [String] {
        guard meeting.inVault, let vault else { return [] }
        var names: [String] = []
        if let client = meeting.setup.client {
            names = [client.name, client.group] + vault.people(for: client)
            for suffix in ["Operativo", "Decisioni", "Identity Card", "Brief creativo"] {
                let n = "\(client.name) - \(suffix)"
                if FileManager.default.fileExists(atPath: vault.clientFolder(client).appendingPathComponent("\(n).md").path) { names.append(n) }
            }
        }
        let allClients = Set(vault.clients().map(\.name))
        names += (meeting.detection?.otherClients ?? []).filter { allClients.contains($0) }
        return Array(Set(names)).sorted()
    }

    private func summarize(_ meeting: inout Meeting, extraLinkable: [String], progress: (String) -> Void) async -> [String] {
        guard !meeting.segments.isEmpty else { return [] }
        progress("Scrivo la nota…")
        let ctx = SummaryContext(title: meeting.setup.title, date: meeting.date, client: meeting.setup.client?.name,
                                 partner: meeting.setup.client?.group, participants: meeting.setup.participantList,
                                 linkableNames: Array(Set(linkableNames(for: meeting) + extraLinkable)).sorted(),
                                 myNotes: meeting.myNotes, template: meeting.setup.template, forVault: meeting.inVault)
        let guidance = meeting.inVault ? CallTemplate.load(config: config).guidance : CallTemplate.plainGuidance
        let (call, provider, errors) = await Summarizer(config: config).summarizeCall(
            transcript: meeting.transcriptText, context: ctx, guidance: guidance)
        guard let call else { return errors }
        meeting.call = call
        meeting.summaryMarkdown = call.markdown
        meeting.summaryProvider = provider
        let userTitle = meeting.setup.title.trimmingCharacters(in: .whitespaces)
        meeting.title = !userTitle.isEmpty ? userTitle : (call.titolo.map(Vault.asciiSafe) ?? meeting.title)
        return errors
    }

    // MARK: - Percorsi nel vault

    /// `YYYY-MM-DD - <Cliente> - <Titolo>`: datato, linkabile (niente [ ]), unico nel vault.
    private func baseName(for m: Meeting, folder: URL) -> String {
        let day = Vault.dayFormatter.string(from: m.date)
        let who = m.setup.client?.name ?? inboxLabel
        var base = Vault.sanitize("\(day) - \(who) - \(m.title)")
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(base).md").path) {
            let hm = DateFormatter()
            hm.dateFormat = "HH-mm"
            base += " (\(hm.string(from: m.date)))"
        }
        return base
    }

    private func vaultPaths(for m: Meeting, vault: Vault) -> (note: URL, transcript: URL, audio: URL) {
        let folder = vault.callsFolder(for: m.setup.client, unassigned: config.vaultUnassignedFolder)
        let base = baseName(for: m, folder: folder)
        // Originali (trascrizione e audio) in raw/ del cliente, come da regola del vault; senza cliente restano in Inbox/.
        let rawFolder = m.setup.client.map { vault.clientFolder($0).appendingPathComponent("raw", isDirectory: true) } ?? folder
        return (folder.appendingPathComponent("\(base).md"),
                rawFolder.appendingPathComponent("\(base) (trascrizione).md"),
                rawFolder.appendingPathComponent("\(base).m4a"))
    }

    private func move(_ meeting: inout Meeting, from previous: Meeting?, vault: Vault) throws {
        let fm = FileManager.default
        let oldNoteName = meeting.noteURL.deletingPathExtension().lastPathComponent
        let oldTranscript = meeting.transcriptPath.map(URL.init(fileURLWithPath:))
        let oldFiles: [URL?] = [meeting.noteURL, oldTranscript, meeting.audioURL]
        let paths = vaultPaths(for: meeting, vault: vault)
        let newFiles = [paths.note, paths.transcript, paths.audio]
        for (old, new) in zip(oldFiles, newFiles) {
            guard let old, fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { continue }
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
        }
        meeting.notePath = paths.note.path
        meeting.transcriptPath = paths.transcript.path
        meeting.audioPath = paths.audio.path

        let newNoteName = paths.note.deletingPathExtension().lastPathComponent
        let link = "[[\(oldNoteName)]]"
        // Cambio di cliente: via le righe aggiunte dall'app per il vecchio cliente (hub, indice, decisioni);
        // la propagazione le riscrive per il nuovo. La riga "da smistare" dell'Inbox sparisce.
        // (Con il solo cambio di titolo queste righe restano: le aggiorna renameLinks qui sotto.)
        if previous != nil {   // indice "da smistare" e daily li riscrive la propagazione, col cliente nuovo
            try? vault.removeIndexLines(containing: link, marker: "da smistare")
            try? vault.removeListLines(in: vault.root.appendingPathComponent("Daily/\(Vault.dayFormatter.string(from: meeting.date)).md"), containing: link)
        }
        if let old = previous?.setup.client {
            try? vault.removeListLines(in: vault.hubURL(old), containing: link)
            try? vault.removeListLines(in: vault.root.appendingPathComponent("index.md"), containing: link)
            try? vault.removeDecisionBlock(client: old, noteLink: link)
        }
        // Tutti gli altri link alla nota e alla trascrizione seguono il nuovo nome (come fa Obsidian quando rinomini).
        if oldNoteName != newNoteName { vault.renameLinks(from: oldNoteName, to: newNoteName) }
        if let oldT = oldTranscript?.deletingPathExtension().lastPathComponent {
            let newT = paths.transcript.deletingPathExtension().lastPathComponent
            if oldT != newT { vault.renameLinks(from: oldT, to: newT) }
        }
        let oldAudio = (oldFiles[2]?.lastPathComponent) ?? ""
        if !oldAudio.isEmpty, oldAudio != paths.audio.lastPathComponent { vault.renameLinks(from: oldAudio, to: paths.audio.lastPathComponent) }
        try? vault.appendLog(date: Date(), entries: [
            "move | \(oldNoteName) -> [[\((vault.relativePath(paths.note) as NSString).deletingPathExtension)]]",
        ])
    }

    // MARK: - Scrittura

    private func write(_ meeting: inout Meeting, newPeople: [String], propagate: Bool) -> [String] {
        var warnings: [String] = []
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: meeting.noteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if meeting.inVault, let vault {
                let renderer = CallNoteRenderer(config: config, vault: vault)
                try renderer.renderNote(meeting, newPeople: newPeople).write(to: meeting.noteURL, atomically: true, encoding: .utf8)
                if let t = meeting.transcriptPath {
                    let url = URL(fileURLWithPath: t)
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try renderer.renderTranscript(meeting).write(to: url, atomically: true, encoding: .utf8)
                }
            } else {
                try SimpleNoteRenderer(config: config).render(meeting).write(to: meeting.noteURL, atomically: true, encoding: .utf8)
            }
        } catch {
            warnings.append("Scrittura nota: \(error.localizedDescription)")
        }
        if propagate, meeting.inVault, let vault, config.bool("PROPAGATE", default: true) {
            do { try self.propagate(meeting, newPeople: newPeople, vault: vault) } catch {
                warnings.append("Propagazione nel vault: \(error.localizedDescription)")
            }
        }
        do { try MeetingStore.save(meeting) } catch { warnings.append("Archivio: \(error.localizedDescription)") }
        return warnings
    }

    // MARK: - Persone nuove

    /// Persone nominate con un ruolo che nel vault non ci sono ancora.
    /// Nome file come da convenzione: "Nome Cognome", oppure "Nome - Cliente" se il cognome non è stato detto.
    private func plannedNewPeople(_ people: [ClientDetection.Person], client: VaultClient, vault: Vault) -> [(name: String, role: String)] {
        guard config.bool("AUTO_PEOPLE", default: true) else { return [] }
        let existing = Set(vault.allPeople())
        let knownFirstNames = Set(vault.people(for: client).compactMap {
            $0.components(separatedBy: CharacterSet(charactersIn: " -")).first?.lowercased()
        })
        var out: [(name: String, role: String)] = []
        for p in people {
            let raw = Vault.sanitize(Vault.asciiSafe(p.name))
            guard !raw.isEmpty, let first = raw.components(separatedBy: " ").first?.lowercased(),
                  !knownFirstNames.contains(first) else { continue }
            let name = raw.contains(" ") ? raw : "\(raw) - \(client.name)"
            guard !existing.contains(name), !vault.personExists(name), !out.contains(where: { $0.name == name }) else { continue }
            out.append((name, Vault.asciiSafe(p.role ?? "")))
        }
        return out
    }

    // MARK: - Propagazione nel vault (tabella "Propagazione" di _CLAUDE.md)

    private func propagate(_ m: Meeting, newPeople: [String], vault: Vault) throws {
        let noteName = m.noteURL.deletingPathExtension().lastPathComponent
        let day = Vault.dayFormatter.string(from: m.date)
        let rel: (URL) -> String = { (vault.relativePath($0) as NSString).deletingPathExtension }
        var log = ["save | \(noteName) -> [[\(rel(m.noteURL))]] (tags: chiamata)"]
        if let t = m.transcriptPath { log.append("save | trascrizione -> [[\(rel(URL(fileURLWithPath: t)))]] (tags: raw)") }

        if let client = m.setup.client {
            let hub = vault.hubURL(client)
            if FileManager.default.fileExists(atPath: hub.path) {
                try vault.appendToSection(hub, heading: "Attività recente", line: "- \(day) - \(m.title) (call registrata): [[\(noteName)]]")
                if let text = try? String(contentsOf: hub, encoding: .utf8), text.contains("\n## Note\n") {
                    try vault.appendToSection(hub, heading: "Note", line: "- [[\(noteName)]]")
                }
                for p in newPeople { try vault.appendToFrontmatterList(hub, key: "referenti", value: "[[\(p)]]") }
                log.append("update | [[\(rel(hub))]] appended")
            }
            for p in newPeople { log.append("save | \(p) -> [[Persone/\(p)]] (tags: persona, da-verificare)") }

            let decisions = (m.call?.decisioni ?? []).map { Vault.asciiSafe(Timestamps.strip($0)) }.filter { !$0.isEmpty }
            if config.bool("PROPAGATE_DECISIONS", default: true), !decisions.isEmpty {
                let file = try vault.appendDecisions(client: client, date: m.date, title: m.title, noteName: noteName, decisions: decisions)
                log.append("update | [[\(rel(file))]] appended")
            }

            var indexLine = "- [[\(noteName)]] - call registrata"
            if let t = m.transcriptPath { indexLine += " · [[\(URL(fileURLWithPath: t).deletingPathExtension().lastPathComponent)]] (raw)" }
            if !newPeople.isEmpty { indexLine += " · nuove persone da verificare: " + newPeople.map { "[[\($0)]]" }.joined(separator: " · ") }
            if try vault.appendToIndex(client: client.name, line: indexLine) { log.append("update | [[index]] appended") }

            try vault.appendDaily(date: m.date, line: "- [[\(client.name)]]: call registrata → [[\(noteName)]]")
        } else {
            let hint = m.detection?.unknownCompany.map { ": dalla call sembra \"\(Vault.asciiSafe($0))\", non ancora nel vault" } ?? ""
            if try vault.appendToIndex(client: nil, line: "- [[\(noteName)]] - call registrata da smistare (cliente non riconosciuto\(hint))") {
                log.append("update | [[index]] appended")
            }
            try vault.appendDaily(date: m.date, line: "- Call registrata da smistare: [[\(noteName)]]")
        }
        try vault.appendLog(date: Date(), entries: log)
    }
}

// MARK: - Note nel vault

/// Nota post call (dal template del vault) e nota raw con trascrizione, appunti e audio.
struct CallNoteRenderer {
    let config: Config
    let vault: Vault

    func renderNote(_ m: Meeting, newPeople: [String]) -> String {
        let day = Vault.dayFormatter.string(from: m.date)
        let hm = DateFormatter()
        hm.locale = Locale(identifier: "en_US_POSIX")
        hm.dateFormat = "HH:mm"
        let created = DateFormatter()
        created.locale = Locale(identifier: "en_US_POSIX")
        created.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        let call = m.call
        let client = m.setup.client
        let transcriptName = m.transcriptPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }

        // Preambolo: quello dell'LLM + le note di provenienza che il vault richiede.
        var preamble = call?.forFutureAgent ?? "Call del \(day)\(client.map { " con [[\($0.name)]]" } ?? ""). Nota non ancora generata: c'è solo la trascrizione."
        if m.setup.clientSource == "automatico", let c = client {
            let evidence = m.detection?.evidence.map { ": \"\($0)\"" } ?? ""
            preamble += " Il cliente [[\(c.name)]] è stato riconosciuto automaticamente dal contenuto della call\(evidence) [Inferito]."
        } else if client == nil {
            preamble += " Cliente non riconosciuto"
            if let company = m.detection?.unknownCompany { preamble += " (dalla call sembra \"\(company)\", che non è ancora nel vault) [Inferito]" }
            preamble += ": nota da smistare nello spazio del cliente giusto."
        }
        if !newPeople.isEmpty {
            preamble += " Persone nuove create in Persone/ da verificare: " + newPeople.map { "[[\($0)]]" }.joined(separator: ", ") + "."
        }
        if let transcriptName { preamble += " Trascrizione integrale e audio in [[\(transcriptName)]]." }

        var collegate: [String] = []
        if let c = client {
            for suffix in ["Operativo", "Decisioni"] {
                let n = "\(c.name) - \(suffix)"
                let decisionsComing = suffix == "Decisioni" && !(call?.decisioni ?? []).isEmpty
                if decisionsComing || FileManager.default.fileExists(atPath: vault.clientFolder(c).appendingPathComponent("\(n).md").path) {
                    collegate.append("[[\(n)]]")
                }
            }
        }
        if let transcriptName { collegate.append("[[\(transcriptName)]]") }

        var participants = call?.partecipanti ?? []
        if participants.isEmpty { participants = m.setup.participantList }

        // I minuti [mm:ss] servono solo nell'app (link cliccabili): nella nota del vault non entrano.
        let sections = (call?.sezioni ?? []).map { s in
            "# \(s.titolo)\n\n" + s.punti.map { "- \(Timestamps.strip($0))" }.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
        var nextSteps = (call?.nextSteps ?? []).map(Timestamps.strip)
        if nextSteps.isEmpty { nextSteps = ["Nessun next step emerso dalla call."] }

        var values: [String: CallTemplate.Value] = [
            "data": .text(day),
            "data_call": .text("\(day) ore \(hm.string(from: m.date))"),
            "created": .text(created.string(from: m.date)),
            "stato": .text(client.flatMap { hubField($0, "stato") } ?? "TBD"),
            "titolo": .text(m.title),
            "for_future_agent": .text(Timestamps.strip(preamble)),
            "summary": .list((call?.summary ?? ["Nota non ancora generata: vedi la trascrizione."]).map(Timestamps.strip)),
            "sezioni": .markdown(sections),
            "next_steps": .list(nextSteps),
            "partecipanti": .list(participants),
            "collegata_a": .list(collegate),
            "tag_tipo": .list(call?.tipo.map { [Vault.tagSlug($0)] } ?? []),
            "tag_cliente": .list([client.map { Vault.tagSlug($0.name) } ?? "da-smistare"]),
            "tag_argomenti": .list((call?.tagArgomenti ?? []).map(Vault.tagSlug).filter { !$0.isEmpty }),
            "audio": .text(m.audioURL.lastPathComponent),
        ]
        if let c = client {
            values["cliente"] = .text(c.name)
            values["partner"] = .text(c.group)
        }
        if let o = call?.obiettivo, !o.isEmpty { values["obiettivo"] = .text(Timestamps.strip(o)) }
        return CallTemplate.load(config: config).render(values)
    }

    func renderTranscript(_ m: Meeting) -> String {
        let day = Vault.dayFormatter.string(from: m.date)
        let noteName = m.noteURL.deletingPathExtension().lastPathComponent
        let title = URL(fileURLWithPath: m.transcriptPath ?? "").deletingPathExtension().lastPathComponent
        let minutes = max(1, Int((m.durationSeconds / 60).rounded()))
        let clientField = m.setup.client.map { "\"[[\($0.name)]]\"" } ?? "TBD"
        let clientLink = m.setup.client.map { " con [[\($0.name)]]" } ?? ""
        var out = """
        ---
        type: raw
        date: \(day)
        tags: [raw, trascrizione, chiamata]
        ai-first: true
        cliente: \(clientField)
        chiamata: "[[\(noteName)]]"
        audio: "[[\(m.audioURL.lastPathComponent)]]"
        durata_min: \(minutes)
        fonte: "Registrazione Meeting Notes, trascrizione \(m.transcriptionEngine)"
        ---
        # \(title)

        ## For future agent
        Originale immutabile della call del \(day)\(clientLink): audio, appunti presi durante la call e trascrizione automatica completa (\(m.transcriptionEngine)). La nota di sintesi è [[\(noteName)]]. "\(config.myName)" = microfono di chi registra, "\(config.othersName)" = audio della call: le attribuzioni ai singoli sono dedotte. Il testo contiene errori di riconoscimento vocale. Non modificare.

        ![[\(m.audioURL.lastPathComponent)]]

        """
        let notes = m.myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { out += "\n## Appunti presi durante la call\n\n\(Vault.asciiSafe(notes))\n" }
        let transcript = m.transcriptText
        out += "\n## Trascrizione\n\n" + (transcript.isEmpty ? "_(nessun parlato rilevato)_" : Vault.asciiSafe(transcript)) + "\n"
        return out
    }

    private func hubField(_ c: VaultClient, _ key: String) -> String? {
        guard let text = try? String(contentsOf: vault.hubURL(c), encoding: .utf8) else { return nil }
        let line = Vault.frontmatter(text).components(separatedBy: "\n").first { $0.hasPrefix("\(key):") }
        let v = line?.dropFirst(key.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        return (v?.isEmpty ?? true) ? nil : v
    }
}

/// Nota fuori dal vault (~/MeetingNotes): sintesi in alto, trascrizione sotto un divisore.
struct SimpleNoteRenderer {
    let config: Config

    func render(_ m: Meeting) -> String {
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd HH:mm"
        let minutes = max(1, Int((m.durationSeconds / 60).rounded()))
        var out = "---\ndate: \(iso.string(from: m.date))\nduration_min: \(minutes)\n"
        out += "transcription: \"\(m.transcriptionEngine)\"\nsummary_model: \"\(m.summaryProvider ?? "none")\"\n"
        out += "audio: \"\(m.audioURL.lastPathComponent)\"\ntags: [meeting]\n---\n\n"
        out += "# \(m.title)\n\nAudio: [\(m.audioURL.lastPathComponent)](\(m.audioURL.lastPathComponent)) · \(minutes) min\n\n"
        if let s = m.summaryMarkdown {
            out += s + "\n"
        } else if m.segments.isEmpty {
            out += "_Nessun parlato rilevato nella registrazione._\n"
        } else {
            out += "> Riepilogo non generato: rigeneralo dall'archivio dell'app.\n"
        }
        let notes = m.myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { out += "\n## I miei appunti\n\n\(notes)\n" }
        let transcript = m.transcriptText
        out += "\n---\n\n## Transcript\n\n" + (transcript.isEmpty ? "_(vuoto)_" : transcript) + "\n"
        return out
    }
}
