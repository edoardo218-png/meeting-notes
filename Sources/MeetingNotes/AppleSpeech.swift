import AVFoundation
import Foundation
import Speech

enum AppleSpeechError: LocalizedError {
    case unavailable
    case unsupportedLocale(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "La trascrizione di Apple richiede macOS 26 o successivo."
        case .unsupportedLocale(let l): return "La trascrizione di Apple non supporta la lingua \"\(l)\"."
        }
    }
}

/// Trascrizione on-device con il motore di macOS (SpeechAnalyzer + SpeechTranscriber, macOS 26+).
/// Restituisce le singole parole con i loro tempi; i turni li ricostruisce `Transcriber.groupWords`.
enum AppleSpeech {
    static func words(in audio: URL, language: String) async throws -> [Segment] {
        guard #available(macOS 26, *) else { throw AppleSpeechError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw AppleSpeechError.unsupportedLocale(language)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        // Il modello della lingua viene scaricato da macOS solo la prima volta.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let file = try AVAudioFile(forReading: audio)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [Segment] in
            var words: [Segment] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                    words.append(Segment(start: range.start.seconds, end: range.end.seconds,
                                         text: text.hasPrefix(" ") ? text : " " + text))
                }
            }
            return words
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        return try await collector.value
    }
}
