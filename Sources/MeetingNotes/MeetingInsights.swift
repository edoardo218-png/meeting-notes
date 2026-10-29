import Foundation

/// Quanto ha parlato chi registra rispetto agli altri, calcolato dalle tracce Io/Altri già salvate
/// (funziona anche sulle riunioni registrate prima di questa funzione).
struct TalkStats {
    let me: Double          // secondi di parlato
    let others: Double
    let longestMe: Double   // intervento più lungo di chi registra

    var total: Double { me + others }
    var meShare: Double { total > 0 ? me / total : 0 }

    static func from(_ segments: [Segment], myName: String, othersName: String) -> TalkStats? {
        var me = 0.0, others = 0.0, longest = 0.0
        var runStart: Double?, runEnd = 0.0
        for s in segments.sorted(by: { $0.start < $1.start }) {
            let d = max(0, s.end - s.start)
            if s.speaker == myName {
                me += d
                if runStart == nil { runStart = s.start }
                runEnd = max(runEnd, s.end)
            } else {
                if s.speaker == othersName { others += d }
                if let st = runStart { longest = max(longest, runEnd - st) }
                runStart = nil
            }
        }
        if let st = runStart { longest = max(longest, runEnd - st) }
        // Senza le due tracce (es. file audio importato) la statistica non ha senso.
        guard me > 0 || others > 0, segments.contains(where: { $0.speaker == myName || $0.speaker == othersName }) else { return nil }
        return TalkStats(me: me, others: others, longestMe: longest)
    }
}

/// Minuti della trascrizione nel testo ("[12:34]"): diventano link cliccabili nell'app e vengono tolti dalle note nel vault.
enum Timestamps {
    /// "[12:34]" o "[1:02:34]" non seguito da "(" (cioè non già un link).
    private static let single = try! NSRegularExpression(pattern: #"\[(\d{1,2}:\d{2}(?::\d{2})?)\](?!\()"#)
    /// "[2 @ 12:34]" (risposte su più riunioni) e "[2]" da solo.
    private static let multiWithTime = try! NSRegularExpression(pattern: #"\[(\d{1,3})\s*@\s*(\d{1,2}:\d{2}(?::\d{2})?)\]"#)
    private static let multiOnly = try! NSRegularExpression(pattern: #"\[(\d{1,3})\](?!\()"#)

    static func seconds(_ ts: String) -> Double? {
        let parts = ts.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }

    /// Toglie i minuti (per la nota nel vault, che resta nel formato del template).
    static func strip(_ s: String) -> String {
        let r = try! NSRegularExpression(pattern: #"\s*\[\d{1,2}:\d{2}(?::\d{2})?\]"#)
        return r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    static func hasTimestamps(_ s: String) -> Bool {
        single.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// "[12:34]" → link Markdown "mn-seek://754" (salta a quel punto dell'audio).
    static func linkify(_ s: String) -> String {
        replace(single, in: s) { m, ns in
            let ts = ns.substring(with: m.range(at: 1))
            guard let sec = seconds(ts) else { return nil }
            return "[\(ts)](mn-seek://\(Int(sec)))"
        }
    }

    /// Risposte su più riunioni: "[2 @ 12:34]" → apre la riunione 2 a quel minuto; "[2]" → apre la riunione 2.
    static func linkifyMulti(_ s: String, sources: [Meeting]) -> String {
        var out = replace(multiWithTime, in: s) { m, ns in
            guard let n = Int(ns.substring(with: m.range(at: 1))), sources.indices.contains(n - 1) else { return nil }
            let ts = ns.substring(with: m.range(at: 2))
            guard let sec = seconds(ts) else { return nil }
            return "[\\[\(n)\\] \(ts)](mn-open://\(sources[n - 1].id)?t=\(Int(sec)))"
        }
        out = replace(multiOnly, in: out) { m, ns in
            guard let n = Int(ns.substring(with: m.range(at: 1))), sources.indices.contains(n - 1) else { return nil }
            return "[\\[\(n)\\]](mn-open://\(sources[n - 1].id))"
        }
        return out
    }

    private static func replace(_ re: NSRegularExpression, in s: String, _ make: (NSTextCheckingResult, NSString) -> String?) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += make(m, ns) ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    // MARK: Riunioni passate (riepiloghi senza minuti)

    private static let stopwords: Set<String> = [
        "della", "delle", "degli", "dello", "nella", "nelle", "negli", "sono", "stato", "stata", "stati", "state", "anche",
        "come", "questo", "questa", "quello", "quella", "perché", "quindi", "però", "mentre", "dopo", "prima", "ogni",
        "tutto", "tutti", "tutte", "viene", "vengono", "essere", "fare", "hanno", "molto", "dove", "quando", "sulla",
        "sulle", "sugli", "dalla", "dalle", "dagli", "alla", "alle", "agli", "loro", "suoi", "nostro", "nostra",
    ]

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stopwords.contains($0) })
    }

    /// Per i riepiloghi senza minuti: a ogni punto elenco aggiunge il minuto del passaggio della trascrizione
    /// più simile (solo per la vista nell'app; il riepilogo salvato non cambia).
    static func annotate(_ markdown: String, turns: [Merge.Turn]) -> String {
        guard !turns.isEmpty, !hasTimestamps(markdown) else { return markdown }
        let turnWords = turns.map { words($0.text) }
        return markdown.components(separatedBy: "\n").map { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- "), !t.hasPrefix("- [ ]") else { return line }
            let w = words(t)
            guard w.count >= 3 else { return line }
            var best = (score: 0.0, matched: 0, index: -1)
            for (i, tw) in turnWords.enumerated() {
                let matched = w.intersection(tw).count
                let score = Double(matched) / Double(w.count)
                if score > best.score { best = (score, matched, i) }
            }
            guard best.index >= 0, best.matched >= 2, best.score >= 0.25 else { return line }
            return line + " [\(Merge.timestamp(turns[best.index].start))]"
        }.joined(separator: "\n")
    }
}
