import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Diagnostica della trascrizione dal vivo (file in ~/Library/Logs/MeetingNotes-live.log).
func liveLog(_ msg: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MeetingNotes-live.log")
    let line = "\(Date()) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

/// Riga della trascrizione dal vivo mostrata nel pannello.
struct LiveLine: Identifiable, Equatable {
    let id: UUID
    let speaker: String
    let isMe: Bool
    let start: Double
    var text: String
    var isFinal: Bool
}

/// Trascrizione in streaming di una traccia (mic o audio della call) con il motore on-device di macOS.
/// Serve solo per la vista dal vivo: la nota finale usa la trascrizione completa fatta a fine registrazione.
@available(macOS 26, *)
final class LiveTranscriber {
    let speaker: String
    let isMe: Bool
    /// (testo, inizio in secondi, definitivo?)
    var onResult: ((String, Double, Bool) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let lock = NSLock()
    private var loggedConversionError = false
    private var firstSeconds: Double?
    private var offset: Double { lock.withLock { firstSeconds ?? 0 } }

    init(speaker: String, isMe: Bool) {
        self.speaker = speaker
        self.isMe = isMe
    }

    func start(language: String) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw AppleSpeechError.unsupportedLocale(language)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        lock.withLock { format = best }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(200))
        self.continuation = continuation
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let offset = self?.offset ?? 0
                    self?.onResult?(text, result.range.start.seconds + offset, result.isFinal)
                }
            } catch {
                liveLog("trascrizione dal vivo interrotta: \(error)")
            }
        }
        // start(inputSequence:) resta in attesa finché il flusso non finisce: va lanciato in background.
        Task { [speaker] in
            do { try await analyzer.start(inputSequence: stream) } catch {
                liveLog("analisi dal vivo (\(speaker)) non avviata: \(error)")
            }
        }
    }

    /// Chiamato dalla callback audio: converte subito (il buffer d'origine vale solo dentro la callback).
    func feed(_ buffer: AVAudioPCMBuffer, at seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let format, let continuation, buffer.frameLength > 0 else { return }
        if converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converterInput = buffer.format
        }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 512
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else {
            if !loggedConversionError { liveLog("conversione live fallita: \(String(describing: error)) \(buffer.format) → \(format)") }
            loggedConversionError = true
            return
        }

        // Niente orario esplicito: il motore richiede audio contiguo e i nostri orari (host time) possono
        // accavallarsi di qualche millisecondo. Conta lui il tempo; noi aggiungiamo lo scarto del primo buffer.
        if firstSeconds == nil { firstSeconds = seconds }
        continuation.yield(AnalyzerInput(buffer: out))
    }

    func stop() async {
        let continuation = lock.withLock { () -> AsyncStream<AnalyzerInput>.Continuation? in
            let c = self.continuation
            self.continuation = nil
            return c
        }
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        analyzer = nil
    }
}
