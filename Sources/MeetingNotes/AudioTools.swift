import AVFoundation

/// Mix e misura del volume con AVFoundation: servono quando ffmpeg non è installato
/// (con la trascrizione di macOS l'app funziona così senza Homebrew).
enum AudioTools {
    enum Failure: LocalizedError {
        case convert(String)
        var errorDescription: String? {
            switch self { case .convert(let s): return "Conversione audio non riuscita: \(s)" }
        }
    }

    /// Somma le tracce (come `amix` con normalize=0), mono, AAC 96 kbps. Dura quanto la traccia più lunga.
    static func mix(_ sources: [URL], to out: URL, sampleRate: Double = 48_000) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw Failure.convert("formato non valido")
        }
        let readers = try sources.map { try Reader(url: $0, to: format) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]
        let file = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 16_384
        guard let sum = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw Failure.convert("buffer") }
        while true {
            var frames: AVAudioFrameCount = 0
            let dst = sum.floatChannelData![0]
            for i in 0..<Int(chunk) { dst[i] = 0 }
            for r in readers {
                guard let b = try r.next(chunk) else { continue }
                let src = b.floatChannelData![0]
                for i in 0..<Int(b.frameLength) { dst[i] += src[i] }
                frames = max(frames, b.frameLength)
            }
            if frames == 0 { break }
            for i in 0..<Int(frames) { dst[i] = min(1, max(-1, dst[i])) }
            sum.frameLength = frames
            try file.write(from: sum)
        }
    }

    /// Picco della traccia in dB (-inf se è vuota).
    static func peakDB(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else { return -.infinity }
        var peak: Float = 0
        while file.framePosition < file.length {
            try file.read(into: buf)
            if buf.frameLength == 0 { break }
            for ch in 0..<Int(buf.format.channelCount) {
                let data = buf.floatChannelData![ch]
                for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(data[i])) }
            }
        }
        return peak > 0 ? 20 * log10(Double(peak)) : -.infinity
    }

    /// Legge un file audio qualsiasi convertendolo al formato del mix, un pezzo alla volta.
    private final class Reader {
        let file: AVAudioFile
        let converter: AVAudioConverter
        let input: AVAudioPCMBuffer
        let format: AVAudioFormat
        var finished = false

        init(url: URL, to format: AVAudioFormat) throws {
            file = try AVAudioFile(forReading: url)
            guard let c = AVAudioConverter(from: file.processingFormat, to: format),
                  let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192) else {
                throw Failure.convert(url.lastPathComponent)
            }
            converter = c
            input = b
            self.format = format
        }

        func next(_ frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
            guard !finished, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
            var readError: Error?
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { [self] _, inputStatus in
                if file.framePosition >= file.length { inputStatus.pointee = .endOfStream; return nil }
                do { try file.read(into: input) } catch { readError = error; inputStatus.pointee = .endOfStream; return nil }
                if input.frameLength == 0 { inputStatus.pointee = .endOfStream; return nil }
                inputStatus.pointee = .haveData
                return input
            }
            if let e = readError ?? error { throw e }
            if status == .endOfStream || status == .error { finished = true }
            return out.frameLength > 0 ? out : nil
        }
    }
}
