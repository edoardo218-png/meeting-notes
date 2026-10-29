import Foundation

enum Merge {
    /// Unisce i segmenti di mic ("Io") e sistema ("Altri") in ordine temporale.
    /// Se si parla senza cuffie il mic ricattura la voce degli altri: un segmento del mic che si
    /// sovrappone nel tempo a uno di sistema con testo quasi uguale viene scartato come eco.
    static func merge(mic: [Segment], system: [Segment], myName: String, othersName: String) -> [Segment] {
        let others = system.map { s -> Segment in var s = s; s.speaker = othersName; return s }
        let mine = mic.filter { m in
            !others.contains { o in overlaps(m, o) && similarity(m.text, o.text) > 0.5 }
        }.map { s -> Segment in var s = s; s.speaker = myName; return s }
        return (mine + others).sorted { $0.start < $1.start }
    }

    struct Turn: Identifiable, Hashable {
        let speaker: String
        let start: Double
        let text: String
        var id: Double { start }
    }

    /// Raggruppa i segmenti consecutivi dello stesso speaker in turni (al massimo ~90 s ciascuno).
    static func turns(_ segments: [Segment]) -> [Turn] {
        var out: [Turn] = []
        var current: (speaker: String, start: Double, text: [String])?
        func flush() {
            if let c = current { out.append(Turn(speaker: c.speaker, start: c.start, text: c.text.joined(separator: " "))) }
        }
        for s in segments {
            if let c = current, c.speaker == s.speaker, s.start - c.start < 90 {
                current?.text.append(s.text)
            } else {
                flush()
                current = (s.speaker, s.start, [s.text])
            }
        }
        flush()
        return out
    }

    /// Formatta il transcript: "[mm:ss] **Speaker:** testo", un turno per paragrafo.
    static func format(_ segments: [Segment]) -> String {
        turns(segments).map { t in
            let who = t.speaker.isEmpty ? "" : "**\(t.speaker):** "
            return "[\(timestamp(t.start))] \(who)\(t.text)"
        }.joined(separator: "\n\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let t = Int(seconds.rounded(.down))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private static func overlaps(_ a: Segment, _ b: Segment) -> Bool {
        a.start < b.end + 2.5 && b.start < a.end + 2.5
    }

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 })
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        return Double(wa.intersection(wb).count) / Double(min(wa.count, wb.count))
    }
}
