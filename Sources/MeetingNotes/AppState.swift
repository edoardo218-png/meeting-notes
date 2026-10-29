import AppKit
import Foundation
import SwiftUI
import UserNotifications

/// Stato condiviso fra menu bar, pannello di registrazione, archivio e impostazioni.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase: Equatable { case idle, starting, recording, stopping }

    // Registrazione
    @Published var phase: Phase = .idle { didSet { if phase != oldValue { NotchBridge.post(self) } } }
    @Published var isPaused = false { didSet { if isPaused != oldValue { NotchBridge.post(self) } } }
    @Published var draft = MeetingSetup()
    @Published var notes = "" { didSet { scheduleNotesSave() } }
    @Published var elapsed: TimeInterval = 0
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var lastError: String?
    /// Notifiche negate in Impostazioni di Sistema: senza, le proposte "Registra" non arrivano.
    @Published var notificationsDenied = false

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in AppState.shared.notificationsDenied = denied }
        }
    }
    /// Trascrizione dal vivo (solo per la vista nel pannello).
    @Published var liveLines: [LiveLine] = []
    @Published var liveStatus: String?
    private var liveTranscribers: [AnyObject] = []
    private var liveVolatile: [String: UUID] = [:]   // speaker → riga provvisoria in corso

    // Dati
    @Published var processing: [String: String] = [:]   // stamp → stato
    @Published var meetings: [Meeting] = []
    @Published var clients: [VaultClient] = []
    @Published var people: [String] = []
    @Published var microphones: [AudioDeviceInfo] = []
    @Published var audioApps: [AudioAppInfo] = []

    let recorder = Recorder()
    let callDetector = CallDetector()
    let linkDetector = MeetingLinkDetector()
    private var meterTimer: Timer?
    private var notesSaveWork: DispatchWorkItem?
    private var silenceWarned = false
    var onChange: (() -> Void)?   // la menu bar si aggiorna

    /// Configurazione in cache: si rilegge quando cambiano le impostazioni e prima di ogni registrazione/elaborazione
    /// (prima veniva riletta dal disco a ogni accesso, anche 10 volte al secondo durante la registrazione).
    private(set) var config = Config.load()
    func reloadConfig() { config = Config.load() }
    var isRecording: Bool { phase == .recording }

    init() {
        recorder.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in
                self?.lastError = error.localizedDescription
                self?.stop()
            }
        }
        callDetector.onCallStarted = { [weak self] d in self?.callStarted(d) }
        callDetector.onCallEnded = { [weak self] d in self?.callEnded(d) }
        linkDetector.onMeetingOpened = { [weak self] d in self?.meetingLinkOpened(d) }
    }

    func applySettings() {
        reloadConfig()
        let cfg = config
        (AppearanceMode(rawValue: cfg.string("APPEARANCE", default: "system")) ?? .system).apply()
        WindowManager.shared.applyDockPolicy()
        // Il controllo del microfono serve sia a proporre la registrazione sia a fermarla a fine call.
        cfg.bool("AUTO_DETECT_CALLS", default: true) || cfg.bool("AUTO_STOP", default: true) ? callDetector.start() : callDetector.stop()
        cfg.bool("DETECT_MEETING_LINKS", default: true) ? linkDetector.start() : linkDetector.stop()
        if cfg.bool("HOTKEY", default: true) { HotKey.register() } else { HotKey.unregister() }
        scheduleAudioCleanup()
    }

    // MARK: - Pulizia dell'audio vecchio

    private var cleanupTimer: Timer?

    /// All'avvio (dopo un minuto) e poi ogni 12 ore. Non tocca le riunioni in elaborazione.
    private func scheduleAudioCleanup() {
        cleanupTimer?.invalidate()
        guard config.int("AUDIO_RETENTION_DAYS", default: 0) > 0 else { cleanupTimer = nil; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.runAudioCleanup() }
        let t = Timer(timeInterval: 12 * 3600, repeats: true) { [weak self] _ in Task { @MainActor in self?.runAudioCleanup() } }
        RunLoop.main.add(t, forMode: .common)
        cleanupTimer = t
    }

    func runAudioCleanup() {
        let cfg = config
        let busy = Set(processing.keys)
        Task.detached {
            let report = AudioCleanup.run(config: cfg, skip: busy)
            guard !report.trashed.isEmpty else { return }
            let mb = Double(report.freedBytes) / 1_000_000
            Notifier.post(title: "Audio vecchio nel Cestino",
                          body: "\(report.trashed.count) registrazioni (\(String(format: "%.0f", mb)) MB). Note e trascrizioni restano.")
        }
    }

    // MARK: - Dati di supporto

    func reloadMeetings() {
        var all = MeetingStore.all()
        // Note spostate nel vault (da Obsidian o da un agent): l'archivio segue il nuovo percorso.
        for i in all.indices where all[i].inVault && !relocateChecked.contains(all[i].id)
            && !FileManager.default.fileExists(atPath: all[i].notePath) {
            relocateChecked.insert(all[i].id)
            if Pipeline(config: config).relocate(&all[i]) { try? MeetingStore.save(all[i]) }
        }
        meetings = all
    }
    private var relocateChecked: Set<String> = []

    func reloadVault() {
        guard let root = config.vaultRoot else { clients = []; people = []; return }
        let vault = Vault(root: root)
        clients = vault.clients()
        people = vault.people(for: draft.client)
    }

    func refreshDevices() async {
        microphones = Recorder.microphones()
        audioApps = await Recorder.audioApps()
    }

    /// Nuova bozza: impostazioni predefinite + evento di calendario in corso (titolo, partecipanti, cliente).
    func prepareDraft() async {
        reloadConfig()
        let cfg = config
        reloadVault()
        var d = MeetingSetup()
        d.template = NoteTemplate(rawValue: cfg.string("DEFAULT_TEMPLATE", default: "generico")) ?? .generico
        d.micDeviceID = cfg["MIC_DEVICE_ID"]
        d.audioAppBundleID = cfg["AUDIO_SOURCE_APP"]
        if cfg.bool("USE_CALENDAR", default: false), let event = await CalendarHelper.currentEvent() {
            d.title = event.title
            d.calendarEvent = event.title
            d.participants = event.attendees.joined(separator: ", ")
            d.client = CalendarHelper.guessClient(event, in: clients)
            if d.client != nil { d.clientSource = "calendario" }
            if d.client != nil, d.template == .generico { d.template = .callCliente }
        }
        draft = d
        notes = ""
        people = config.vaultRoot.map { Vault(root: $0).people(for: d.client) } ?? []
    }

    // MARK: - Registrazione

    func start() async {
        guard phase == .idle else { return }
        phase = .starting
        lastError = nil
        reloadConfig()
        let cfg = config
        let stamp = Pipeline.freshStamp(for: Date(), config: cfg)
        let folder = cfg.recordingsDir.appendingPathComponent(stamp, isDirectory: true)
        do {
            try await recorder.start(into: folder, setup: draft)
            phase = .recording
            isPaused = false
            silenceWarned = false
            systemSilentWarned = false
            silenceBaseline = Date()
            startMeters()
            startLive()
        } catch {
            try? FileManager.default.removeItem(at: folder)
            phase = .idle
            lastError = "Impossibile avviare la registrazione: \(error.localizedDescription). Controlla in Impostazioni di Sistema → Privacy e sicurezza → Registrazione schermo e audio di sistema → \"Solo registrazione audio di sistema\" che MeetingNotes sia abilitata."
        }
        onChange?()
    }

    /// Avvio rapido (scorciatoia, notifica, menu): bozza (titolo dalla scheda della call, se c'è) e via.
    func quickStart(title: String? = nil) async {
        guard phase == .idle else { return }
        await prepareDraft()
        if let title, !title.isEmpty, draft.title.isEmpty { draft.title = title }
        lastQuickStart = Date()
        await start()
        // Nessuna finestra: la registrazione si controlla dal menu in alto o aprendo l'app.
        // Si apre solo se l'avvio fallisce, per mostrare l'errore.
        if lastError != nil { WindowManager.shared.showPanel(activate: false) }
    }

    func togglePause() {
        guard isRecording else { return }
        if recorder.isPaused {
            recorder.resume()
            silenceBaseline = Date()   // la pausa non conta come silenzio
        } else {
            recorder.pause()
        }
        isPaused = recorder.isPaused
        onChange?()
    }

    func stop() {
        guard isRecording else { return }
        phase = .stopping
        stopMeters()
        stopLive()
        saveNotesNow()
        let setup = draft
        Task {
            do {
                let folder = try await recorder.stop(setup: setup)
                phase = .idle
                isPaused = false
                onChange?()
                WindowManager.shared.closePanel()
                process(folder)
            } catch {
                phase = .idle
                lastError = error.localizedDescription
                onChange?()
            }
        }
    }

    // MARK: - Trascrizione dal vivo

    private func startLive() {
        liveLines = []
        liveVolatile = [:]
        liveStatus = nil
        guard config.bool("LIVE_TRANSCRIPT", default: true) else { return }
        guard #available(macOS 26, *) else { liveStatus = "La trascrizione dal vivo richiede macOS 26."; return }
        let language = config.transcribeLanguage == "auto" ? config.notesLanguage : config.transcribeLanguage
        let mine = LiveTranscriber(speaker: config.myName, isMe: true)
        let others = LiveTranscriber(speaker: config.othersName, isMe: false)
        for t in [mine, others] {
            let speaker = t.speaker, isMe = t.isMe
            t.onResult = { [weak self] text, start, isFinal in
                Task { @MainActor in self?.liveResult(speaker: speaker, isMe: isMe, text: text, start: start, isFinal: isFinal) }
            }
        }
        liveTranscribers = [mine, others]
        liveStatus = "Avvio la trascrizione dal vivo…"
        Task {
            do {
                try await mine.start(language: language)
                try await others.start(language: language)
                // Solo ora: prima del via i buffer andrebbero persi comunque.
                recorder.liveSink.set { buffer, isMe, t in (isMe ? mine : others).feed(buffer, at: t) }
                liveStatus = nil
            } catch {
                liveLog("avvio fallito: \(error)")
                liveStatus = "Trascrizione dal vivo non disponibile: \(error.localizedDescription)"
            }
        }
    }

    private func stopLive() {
        recorder.liveSink.set(nil)
        let running = liveTranscribers
        liveTranscribers = []
        if #available(macOS 26, *) {
            Task { for case let t as LiveTranscriber in running { await t.stop() } }
        }
    }

    private func liveResult(speaker: String, isMe: Bool, text: String, start: Double, isFinal: Bool) {
        if let id = liveVolatile[speaker], let i = liveLines.firstIndex(where: { $0.id == id }) {
            liveLines[i].text = text
            liveLines[i].isFinal = isFinal
            if isFinal { liveVolatile[speaker] = nil }
        } else {
            let line = LiveLine(id: UUID(), speaker: speaker, isMe: isMe, start: start, text: text, isFinal: isFinal)
            // Inserimento in ordine di tempo (i due flussi arrivano intrecciati).
            let at = liveLines.lastIndex(where: { $0.start <= start }).map { $0 + 1 } ?? 0
            liveLines.insert(line, at: at)
            if !isFinal { liveVolatile[speaker] = line.id }
        }
        if isFinal { removeLiveEcho() }
        if liveLines.count > 400 { liveLines.removeFirst(liveLines.count - 400) }
    }

    /// Senza cuffie il microfono riprende anche gli altri: una frase "mia" quasi uguale a una degli altri,
    /// detta negli stessi secondi, è un'eco e non va mostrata (stesso criterio della nota finale).
    private func removeLiveEcho() {
        let others = liveLines.filter { !$0.isMe && $0.isFinal }
        liveLines.removeAll { line in
            line.isMe && line.isFinal && others.contains { o in
                abs(o.start - line.start) < 8 && Merge.similarity(o.text, line.text) > 0.5
            }
        }
    }

    /// Clic su una frase dal vivo: la aggiunge agli appunti con il minuto.
    func bookmark(_ line: LiveLine) {
        if !notes.isEmpty && !notes.hasSuffix("\n") { notes += "\n" }
        notes += "★ [\(Merge.timestamp(line.start))] \(line.speaker): \"\(line.text)\"\n"
    }

    /// Segna il momento attuale negli appunti.
    func bookmark() {
        let t = Merge.timestamp(recorder.elapsed)
        if !notes.isEmpty && !notes.hasSuffix("\n") { notes += "\n" }
        notes += "★ [\(t)] "
    }

    /// Titolo, cliente, partecipanti modificati durante la registrazione: salviamo subito nei metadati.
    /// Le persone suggerite si ricalcolano solo quando cambia il cliente (prima: a ogni tasto premuto nel titolo).
    private var peopleClient: VaultClient??
    func draftChanged() {
        if isRecording { try? recorder.writeMeta(setup: draft) }
        if peopleClient != .some(draft.client) {
            peopleClient = .some(draft.client)
            people = config.vaultRoot.map { Vault(root: $0).people(for: draft.client) } ?? []
        }
    }

    /// Uscita dall'app durante una registrazione: salva appunti e tracce (si rielaborano dal menu).
    func stopForQuit() async {
        guard isRecording else { return }
        stopMeters()
        stopLive()
        saveNotesNow()
        _ = try? await recorder.stop(setup: draft)
        phase = .idle
    }

    private func startMeters() {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickMeters() }
        }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    private func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
        micLevel = 0
        systemLevel = 0
        systemAudioHint = nil
    }

    private var lastMenuSecond = -1
    /// Ultimo avvio rapido: subito dopo, una "riattivazione" dell'app (clic sulla notifica) non deve aprire l'archivio.
    var lastQuickStart = Date.distantPast
    private var silenceBaseline = Date()
    private var systemSilentWarned = false
    /// Nessun audio dagli altri nei primi 30 secondi: spesso è il permesso "audio di sistema" negato
    /// (macOS non dà errore, registra silenzio). Lo segnaliamo nel pannello.
    @Published var systemAudioHint: String?

    private func tickMeters() {
        elapsed = recorder.elapsed
        micLevel = recorder.micLevel
        systemLevel = recorder.systemLevel
        let sec = Int(elapsed)
        if sec != lastMenuSecond { lastMenuSecond = sec; onChange?() }
        if !systemSilentWarned, elapsed > 30, !isPaused {
            systemSilentWarned = true
            if !recorder.systemHeardSomething {
                systemAudioHint = "Dagli altri non arriva audio da 30 secondi. Se la call è già iniziata, controlla Impostazioni di Sistema → Privacy e sicurezza → Registrazione schermo e audio di sistema → \"Solo registrazione audio di sistema\"."
            }
        }
        if systemAudioHint != nil, recorder.systemHeardSomething { systemAudioHint = nil }
        // Silenzio prolungato: probabilmente la call è finita.
        let minutes = config.int("SILENCE_STOP_MIN", default: 5)
        let lastSound = max(recorder.lastSoundAt, silenceBaseline)
        if minutes > 0, !isPaused, !silenceWarned, Date().timeIntervalSince(lastSound) > Double(minutes * 60) {
            silenceWarned = true
            Notifier.post(title: "Nessun audio da \(minutes) minuti",
                          body: "La riunione sembra finita. Vuoi fermare la registrazione?", category: Notifier.stopCategory)
        }
    }

    // MARK: - Appunti (salvati in notes.md nella cartella della registrazione, a prova di crash)

    private func scheduleNotesSave() {
        notesSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.saveNotesNow() } }
        notesSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func saveNotesNow() {
        guard let folder = recorder.folder else { return }
        try? notes.write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    }

    // MARK: - Elaborazione

    func process(_ input: URL) {
        let stamp = input.deletingPathExtension().lastPathComponent
        guard processing[stamp] == nil else { return }
        processing[stamp] = "In coda…"
        onChange?()
        reloadConfig()
        let cfg = config
        Task {
            do {
                let result = try await Pipeline(config: cfg).process(input) { msg in
                    // Solo se è ancora in corso: un aggiornamento in ritardo non deve "riaccendere" la voce.
                    Task { @MainActor in
                        guard self.processing[stamp] != nil else { return }
                        self.processing[stamp] = msg
                        self.onChange?()
                    }
                }
                finished(result)
            } catch {
                Notifier.post(title: "Elaborazione fallita",
                              body: "\(error.localizedDescription) · Le tracce restano in \(input.path)")
            }
            processing[stamp] = nil
            onChange?()
        }
    }

    /// Rigenera la nota; se nel frattempo è cambiato il cliente, la sposta nella sua cartella del vault.
    func regenerate(_ meeting: Meeting) {
        guard processing[meeting.id] == nil else { return }
        processing[meeting.id] = "Rigenero…"
        onChange?()
        let cfg = config
        let previous = meetings.first { $0.id == meeting.id }
        Task {
            let result = await Pipeline(config: cfg).regenerate(meeting, previous: previous) { msg in
                Task { @MainActor in
                    guard self.processing[meeting.id] != nil else { return }
                    self.processing[meeting.id] = msg
                }
            }
            finished(result)
            processing[meeting.id] = nil
            onChange?()
        }
    }

    private func finished(_ result: Pipeline.Result) {
        reloadMeetings()
        let m = result.meeting
        let body: String
        if let provider = m.summaryProvider {
            body = "Riepilogo con \(provider)" + (m.inVault ? (m.setup.client.map { " · in \($0.name)" } ?? " · in Inbox, da smistare") : "")
        } else if m.segments.isEmpty {
            body = "Nessun parlato rilevato nella registrazione."
        } else {
            body = "Trascrizione salvata, nota non generata" + (result.warnings.first.map { ": \($0)" } ?? ".")
        }
        Notifier.post(title: "Nota pronta: \(m.title)", body: body, userInfo: ["meeting": m.id])
    }

    /// Titolo, cliente o tipo modificati: niente nuovo riassunto, solo file e link aggiornati.
    func updateDetails(_ meeting: Meeting) {
        guard processing[meeting.id] == nil, let previous = meetings.first(where: { $0.id == meeting.id }) else { return }
        let result = Pipeline(config: config).updateDetails(meeting, previous: previous)
        reloadMeetings()
        if !result.warnings.isEmpty { Notifier.post(title: "Modifica salvata con avvisi", body: result.warnings.joined(separator: "; ")) }
    }

    func delete(_ meeting: Meeting, deleteFiles: Bool) {
        let warnings = Pipeline(config: config).delete(meeting, deleteFiles: deleteFiles)
        reloadMeetings()
        if !warnings.isEmpty { Notifier.post(title: "Eliminazione incompleta", body: warnings.joined(separator: "; ")) }
    }

    func processPending() {
        let fm = FileManager.default
        let current = recorder.folder?.lastPathComponent
        let folders = ((try? fm.contentsOfDirectory(at: config.recordingsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath && $0.lastPathComponent != current }
        if folders.isEmpty { Notifier.post(title: "Nessuna registrazione in sospeso", body: ""); return }
        folders.sorted { $0.path < $1.path }.forEach(process)
    }

    func importAudio(_ url: URL) { process(url) }

    func ask(_ question: String, about meeting: Meeting) async -> String {
        do {
            return try await Summarizer(config: config).ask(question: question, transcript: meeting.transcriptText, meeting: meeting)
        } catch {
            return "**Non è stato possibile rispondere.** \(error.localizedDescription)"
        }
    }

    // MARK: - Rilevamento call

    /// Link di una call aperto nel browser (sala d'attesa): proponiamo di registrare prima ancora del microfono.
    private func meetingLinkOpened(_ d: MeetingLinkDetector.Detection) {
        guard phase == .idle else { return }
        Notifier.post(title: "Stai entrando in una call su \(d.service)",
                      body: d.title.map { "\"\($0)\" · Vuoi registrarla?" } ?? "Vuoi registrarla?",
                      category: Notifier.startCategory, userInfo: ["title": d.title ?? "", "app": d.browserBundleID])
    }

    private func callStarted(_ d: CallDetector.Detection) {
        guard phase == .idle, config.bool("AUTO_DETECT_CALLS", default: true) else { return }
        // Già proposta dal link nel browser negli ultimi minuti: niente seconda notifica.
        if let (link, at) = linkDetector.lastDetection, Date().timeIntervalSince(at) < 10 * 60,
           link.browserBundleID == d.bundleID { return }
        Notifier.post(title: "Call rilevata su \(d.appName)", body: "Vuoi registrarla?",
                      category: Notifier.startCategory, userInfo: ["app": d.bundleID])
    }

    private func callEnded(_ d: CallDetector.Detection) {
        guard isRecording else { return }
        if config.bool("AUTO_STOP", default: true) {
            stop()
            Notifier.post(title: "Call su \(d.appName) terminata", body: "Registrazione fermata: sto preparando la nota.")
        } else {
            Notifier.post(title: "La call su \(d.appName) sembra terminata", body: "Vuoi fermare la registrazione?",
                          category: Notifier.stopCategory)
        }
    }
}

/// Notifiche con azioni ("Registra", "Ferma").
enum Notifier {
    static let startCategory = "CALL_START"
    static let stopCategory = "CALL_END"

    /// Copia del logo in una cartella temporanea (macOS sposta il file allegato, quindi ne serve una copia ogni volta).
    private static func logoAttachment() -> UNNotificationAttachment? {
        guard let src = Bundle.main.url(forResource: "NotificationIcon", withExtension: "png") else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mn-logo-\(UUID().uuidString).png")
        guard (try? FileManager.default.copyItem(at: src, to: tmp)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "logo", url: tmp, options: nil)
    }

    static func setup(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([
            UNNotificationCategory(identifier: startCategory,
                                   actions: [UNNotificationAction(identifier: "RECORD", title: "Registra", options: [])],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: stopCategory,
                                   actions: [UNNotificationAction(identifier: "STOP", title: "Ferma registrazione", options: [])],
                                   intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, category: String? = nil, userInfo: [String: String] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        content.userInfo = userInfo
        // Logo come immagine allegata: si vede anche se macOS ha in cache una vecchia icona dell'app.
        if let logo = logoAttachment() { content.attachments = [logo] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
