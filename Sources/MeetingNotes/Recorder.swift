import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Metadati salvati accanto alle tracce grezze di una registrazione.
struct RecordingMeta: Codable {
    var startedAt: Date
    var durationSeconds: Double
    var micCaptured: Bool
    var setup: MeetingSetup?
}

struct AudioDeviceInfo: Identifiable, Hashable { let id: String; let name: String }
struct AudioAppInfo: Identifiable, Hashable { let id: String; let name: String }

enum RecorderError: LocalizedError {
    case notRecording
    case coreAudio(String, OSStatus)
    var errorDescription: String? {
        switch self {
        case .notRecording: return "Nessuna registrazione in corso."
        case .coreAudio(let what, let status): return "\(what) non riuscito (Core Audio \(status))."
        }
    }
}

// MARK: - Orologio della sessione

/// Converte l'host time dei buffer in secondi dall'inizio della registrazione, pause escluse.
/// Mic e audio di sistema usano lo stesso orologio, quindi le due tracce restano allineate.
final class SessionClock {
    private let lock = NSLock()
    private var start: UInt64 = 0
    private var pausedAt: UInt64?
    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    static func seconds(ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    func reset() { lock.lock(); start = mach_absolute_time(); pausedAt = nil; lock.unlock() }
    func pause() { lock.lock(); if pausedAt == nil { pausedAt = mach_absolute_time() }; lock.unlock() }

    /// Sposta l'origine in avanti della durata della pausa: le tracce restano contigue.
    func resume() {
        lock.lock()
        if let p = pausedAt { start += mach_absolute_time() - p; pausedAt = nil }
        lock.unlock()
    }

    /// nil se in pausa (il buffer va scartato).
    func position(of hostTime: UInt64) -> Double? {
        lock.lock(); defer { lock.unlock() }
        if pausedAt != nil { return nil }
        let t = hostTime == 0 ? mach_absolute_time() : hostTime
        return t > start ? SessionClock.seconds(ticks: t - start) : 0
    }
}

// MARK: - Scrittura di una traccia

/// Scrive una traccia mono 48 kHz in CAF. Ogni buffer viene posizionato al suo istante:
/// i buchi (silenzio senza buffer, cambio dispositivo) si riempiono di zeri, così mic e sistema restano sincronizzati.
final class TrackWriter {
    static let sampleRate: Double = 48_000
    let url: URL
    private let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: TrackWriter.sampleRate,
                                           channels: 1, interleaved: false)!
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private var reportedError = false

    // Livello (picco 0…1) e ultimo istante con suono, letti dalla UI.
    private let lock = NSLock()
    private var _level: Float = 0
    private var _lastSoundAt = Date()
    private var _heardSomething = false
    var level: Float { lock.lock(); defer { lock.unlock() }; return _level }
    var heardSomething: Bool { lock.lock(); defer { lock.unlock() }; return _heardSomething }
    var lastSoundAt: Date { lock.lock(); defer { lock.unlock() }; return _lastSoundAt }

    init(url: URL) { self.url = url }

    /// Va chiamato dallo stesso thread/coda per tutta la registrazione.
    func append(_ buffer: AVAudioPCMBuffer, at seconds: Double) {
        do {
            try appendThrowing(buffer, at: seconds)
        } catch {
            if !reportedError { NSLog("MeetingNotes: errore scrittura \(url.lastPathComponent): \(error)") }
            reportedError = true
        }
    }

    private func appendThrowing(_ inBuf: AVAudioPCMBuffer, at seconds: Double) throws {
        guard inBuf.frameLength > 0 else { return }
        if file == nil {
            // Su disco PCM 16 bit (metà spazio rispetto a float 32); in memoria si lavora in float.
            var settings = fileFormat.settings
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        let expected = AVAudioFramePosition(seconds * TrackWriter.sampleRate)
        let gap = expected - framesWritten
        if gap > AVAudioFramePosition(TrackWriter.sampleRate * 0.05) {
            try writeSilence(frames: gap)
        }

        let inFormat = inBuf.format
        if converterInput != inFormat {
            converter = AVAudioConverter(from: inFormat, to: fileFormat)
            converterInput = inFormat
        }
        guard let converter, let file else { return }
        let ratio = fileFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if status == .error, let convError { throw convError }
        if outBuf.frameLength > 0 {
            meter(outBuf)
            try file.write(from: outBuf)
            framesWritten += AVAudioFramePosition(outBuf.frameLength)
        }
    }

    private func meter(_ buf: AVAudioPCMBuffer) {
        guard let data = buf.floatChannelData?[0] else { return }
        var peak: Float = 0
        for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(data[i])) }
        lock.lock()
        _level = max(peak, _level * 0.6) // decadimento morbido
        if peak > 0.02 { _lastSoundAt = Date(); _heardSomething = true }
        lock.unlock()
    }

    private func writeSilence(frames: AVAudioFramePosition) throws {
        guard let file else { return }
        var remaining = frames
        while remaining > 0 {
            let n = AVAudioFrameCount(min(48_000, remaining))
            guard let buf = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: n) else { return }
            buf.frameLength = n // la memoria è già azzerata
            try file.write(from: buf)
            remaining -= AVAudioFramePosition(n)
            framesWritten += AVAudioFramePosition(n)
        }
    }

    func close() {
        file?.close()
        file = nil
    }

    var hasAudio: Bool { framesWritten > 0 }
}

// MARK: - Audio di sistema: Core Audio process tap

/// Cattura l'audio che le app mandano agli altoparlanti (tutte tranne questa, oppure una sola app)
/// con un process tap di Core Audio (macOS 14.4+). Richiede solo il permesso "Registrazione audio di sistema".
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    /// Coda condivisa da tutti i tap: se il tap viene ricreato (cambio uscita audio) le callback del vecchio
    /// e del nuovo non possono sovrapporsi sullo stesso file.
    static let queue = DispatchQueue(label: "meetingnotes.tap", qos: .userInitiated)
    private var queue: DispatchQueue { SystemAudioTap.queue }
    var onBuffer: ((AVAudioPCMBuffer, UInt64) -> Void)?

    func start(appBundleID: String?) throws {
        let description = makeDescription(appBundleID: appBundleID)
        description.uuid = UUID()
        description.name = "Meeting Notes"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creazione del tap audio")

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = CoreAudioUtil.address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "Lettura formato del tap")
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecorderError.coreAudio("Formato del tap", -1)
        }

        // Il tap si legge tramite un aggregate device privato agganciato all'uscita audio attuale.
        let outputUID = CoreAudioUtil.defaultOutputDeviceUID() ?? ""
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Notes Tap",
            kAudioAggregateDeviceUIDKey: "meetingnotes-tap-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID), "Creazione del dispositivo aggregato")

        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, queue) { [weak self] _, input, inputTime, _, _ in
            // Il buffer è valido solo dentro questo blocco: va scritto subito.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            let t = inputTime.pointee
            let host = t.mFlags.contains(.hostTimeValid) ? t.mHostTime : 0
            self?.onBuffer?(buffer, host)
        }, "Creazione della callback audio")
        try check(AudioDeviceStart(aggregateID, ioProc), "Avvio della cattura")
    }

    /// Tutto l'audio tranne questa app, oppure solo l'app scelta (anche se si riavvia, su macOS 26+).
    private func makeDescription(appBundleID: String?) -> CATapDescription {
        if let bundle = appBundleID {
            let processes = CoreAudioUtil.processObjects(matchingBundle: bundle)
            if #available(macOS 26, *) {
                let d = CATapDescription(__stereoMixdownOfProcesses: processes.map { NSNumber(value: $0.id) })
                // Le app con processi helper (browser, Teams) hanno bundle ID derivati: li includiamo tutti.
                d.bundleIDs = Array(Set([bundle] + processes.map(\.bundleID)))
                d.isProcessRestoreEnabled = true
                return d
            }
            if !processes.isEmpty {
                return CATapDescription(__stereoMixdownOfProcesses: processes.map { NSNumber(value: $0.id) })
            }
            NSLog("MeetingNotes: \(bundle) non sta ancora usando l'audio, registro tutto l'audio di sistema")
        }
        let own = CoreAudioUtil.processObject(pid: getpid()).map { [NSNumber(value: $0)] } ?? []
        return CATapDescription(__stereoGlobalTapButExcludeProcesses: own)
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProc)
            if let ioProc { AudioDeviceDestroyIOProcID(aggregateID, ioProc) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProc = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { stop(); throw RecorderError.coreAudio(what, status) }
    }
}

// MARK: - Microfono: AVAudioEngine

final class MicCapture {
    private var engine = AVAudioEngine()
    private var deviceUID: String?
    var onBuffer: ((AVAudioPCMBuffer, UInt64) -> Void)?
    private var configObserver: NSObjectProtocol?

    func start(deviceUID: String?) throws {
        self.deviceUID = deviceUID
        try startEngine()
        // Cuffie collegate/scollegate durante la call: ripartiamo sul nuovo dispositivo.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? AVAudioEngine) === self.engine else { return }
            NSLog("MeetingNotes: cambio dispositivo microfono, riavvio la cattura")
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            self.engine = AVAudioEngine()
            try? self.startEngine()
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        if let uid = deviceUID, let id = CoreAudioUtil.deviceID(forUID: uid), let unit = input.audioUnit {
            var device = id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.coreAudio("Microfono", -1) }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            self?.onBuffer?(buffer, when.isHostTimeValid ? when.hostTime : 0)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

// MARK: - Uscita verso la trascrizione dal vivo

/// Contenitore thread-safe del destinatario dei buffer (impostato e tolto dal main thread, letto dalle callback audio).
final class LiveSink {
    private let lock = NSLock()
    private var handler: ((AVAudioPCMBuffer, Bool, Double) -> Void)?
    func set(_ h: ((AVAudioPCMBuffer, Bool, Double) -> Void)?) { lock.lock(); handler = h; lock.unlock() }
    func send(_ b: AVAudioPCMBuffer, isMe: Bool, at t: Double) {
        lock.lock(); let h = handler; lock.unlock()
        h?(b, isMe, t)
    }
}

// MARK: - Recorder

/// Registra audio di sistema (process tap) + microfono (AVAudioEngine) su due tracce allineate.
final class Recorder: NSObject {
    private var tap: SystemAudioTap?
    private var mic: MicCapture?
    private var systemTrack: TrackWriter?
    private var micTrack: TrackWriter?
    private let clock = SessionClock()
    private var startedAt = Date()
    private var micCaptured = false
    private var pausedAtDate: Date?
    private var pausedTotal: TimeInterval = 0
    private var currentSetup = MeetingSetup()
    private var outputListener: AudioObjectPropertyListenerBlock?
    private(set) var folder: URL?
    /// Riceve ogni buffer (con la sua posizione) per la trascrizione dal vivo: (buffer, è il mic?, secondi).
    let liveSink = LiveSink()
    var onUnexpectedStop: ((Error) -> Void)?

    var isRecording: Bool { folder != nil }
    var isPaused: Bool { pausedAtDate != nil }

    /// Secondi registrati, pause escluse.
    var elapsed: TimeInterval {
        guard isRecording else { return 0 }
        let pausing = pausedAtDate.map { Date().timeIntervalSince($0) } ?? 0
        return Date().timeIntervalSince(startedAt) - pausedTotal - pausing
    }

    var micLevel: Float { micTrack?.level ?? 0 }
    var systemHeardSomething: Bool { systemTrack?.heardSomething ?? false }
    var systemLevel: Float { systemTrack?.level ?? 0 }
    /// Ultimo momento in cui si è sentito qualcosa (mic o sistema).
    var lastSoundAt: Date {
        [micTrack?.lastSoundAt, systemTrack?.lastSoundAt].compactMap { $0 }.max() ?? startedAt
    }

    // MARK: Dispositivi

    static func microphones() -> [AudioDeviceInfo] { CoreAudioUtil.inputDevices() }

    /// App aperte da cui si può registrare solo l'audio (le app di call per prime).
    static func audioApps() async -> [AudioAppInfo] {
        let mine = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AudioAppInfo? in
                guard let id = app.bundleIdentifier, id != mine, seen.insert(id).inserted else { return nil }
                return AudioAppInfo(id: id, name: CallApps.names[id] ?? app.localizedName ?? id)
            }
            .sorted {
                let c0 = CallApps.isCallApp($0.id), c1 = CallApps.isCallApp($1.id)
                return c0 != c1 ? c0 : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    // MARK: Start / stop

    func start(into folder: URL, setup: MeetingSetup) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        currentSetup = setup

        // Il permesso del microfono va chiesto esplicitamente; se negato registriamo solo l'audio di sistema.
        micCaptured = await AVCaptureDevice.requestAccess(for: .audio)

        let systemTrack = TrackWriter(url: folder.appendingPathComponent("system.caf"))
        self.systemTrack = systemTrack
        clock.reset()
        startedAt = Date()
        pausedAtDate = nil
        pausedTotal = 0

        // Al primo avvio macOS chiede il permesso "Registrazione audio di sistema".
        try startTap(into: systemTrack)
        self.folder = folder   // da qui isRecording = true

        if micCaptured {
            let micTrack = TrackWriter(url: folder.appendingPathComponent("mic.caf"))
            let mic = MicCapture()
            mic.onBuffer = { [clock, liveSink] buffer, host in
                if let t = clock.position(of: host) {
                    micTrack.append(buffer, at: t)
                    liveSink.send(buffer, isMe: true, at: t)
                }
            }
            do {
                try mic.start(deviceUID: setup.micDeviceID)
                self.mic = mic
                self.micTrack = micTrack
            } catch {
                NSLog("MeetingNotes: microfono non disponibile: \(error)")
                micCaptured = false
            }
        }
        watchOutputDevice()
        try writeMeta(setup: setup)
    }

    private func startTap(into track: TrackWriter) throws {
        let tap = SystemAudioTap()
        tap.onBuffer = { [clock, liveSink] buffer, host in
            if let t = clock.position(of: host) {
                track.append(buffer, at: t)
                liveSink.send(buffer, isMe: false, at: t)
            }
        }
        try tap.start(appBundleID: currentSetup.audioAppBundleID)
        self.tap = tap
    }

    /// Se cambia l'uscita audio (es. si collegano gli AirPods) ricreiamo il tap sul nuovo dispositivo.
    private func watchOutputDevice() {
        var addr = CoreAudioUtil.address(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let self, let track = self.systemTrack, self.isRecording else { return }
                NSLog("MeetingNotes: cambio uscita audio, riavvio il tap")
                self.tap?.stop()
                self.tap = nil
                do { try self.startTap(into: track) } catch { self.onUnexpectedStop?(error) }
            }
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
    }

    private func unwatchOutputDevice() {
        guard let outputListener else { return }
        var addr = CoreAudioUtil.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, outputListener)
        self.outputListener = nil
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        clock.pause()
        pausedAtDate = Date()
    }

    func resume() {
        guard let pausedAtDate else { return }
        clock.resume()
        pausedTotal += Date().timeIntervalSince(pausedAtDate)
        self.pausedAtDate = nil
    }

    /// Ferma la cattura, chiude i file e restituisce la cartella con system.caf / mic.caf / meta.json.
    func stop(setup: MeetingSetup) async throws -> URL {
        guard let folder, isRecording else { throw RecorderError.notRecording }
        if isPaused { resume() }
        let duration = elapsed
        unwatchOutputDevice()
        tap?.stop()
        mic?.stop()
        tap = nil
        mic = nil
        // Lasciamo finire le callback in volo prima di chiudere i file.
        SystemAudioTap.queue.sync {}
        try? await Task.sleep(nanoseconds: 150_000_000)
        systemTrack?.close()
        micTrack?.close()
        let micHasAudio = micCaptured && (micTrack?.hasAudio ?? false)
        try writeMeta(setup: setup, folder: folder, duration: duration, micCaptured: micHasAudio)
        systemTrack = nil
        micTrack = nil
        self.folder = nil
        return folder
    }

    /// Salva i metadati (anche durante la registrazione, così un crash non perde titolo e cliente).
    func writeMeta(setup: MeetingSetup, folder: URL? = nil, duration: Double? = nil, micCaptured: Bool? = nil) throws {
        guard let folder = folder ?? self.folder else { return }
        currentSetup = setup
        let meta = RecordingMeta(startedAt: startedAt, durationSeconds: duration ?? elapsed,
                                 micCaptured: micCaptured ?? self.micCaptured, setup: setup)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .prettyPrinted
        try enc.encode(meta).write(to: folder.appendingPathComponent("meta.json"))
    }
}

// MARK: - Utilità Core Audio

enum CoreAudioUtil {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func defaultOutputDeviceUID() -> String? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
            .first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// Dispositivi con almeno un canale d'ingresso (microfoni), escluso l'aggregate privato del tap.
    static func inputDevices() -> [AudioDeviceInfo] {
        objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { id in
            guard !objectList(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).isEmpty,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("meetingnotes-"),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioDeviceInfo(id: uid, name: name)
        }
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// Processi audio dell'app (incluse le helper, es. com.google.Chrome.helper).
    static func processObjects(matchingBundle bundle: String) -> [(id: AudioObjectID, bundleID: String)] {
        objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { id in
            guard let b = string(id, kAudioProcessPropertyBundleID), b == bundle || b.hasPrefix(bundle + ".") else { return nil }
            return (id, b)
        }
    }
}
