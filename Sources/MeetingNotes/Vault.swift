import Foundation

/// Accesso al vault Obsidian secondo le convenzioni di `_CLAUDE.md`:
/// clienti in `Clienti/<Agenzia>/<Nome>/` con hub `<Nome>.md`, chiamate in `Chiamate/` (o `Call/`),
/// persone in `Persone/`, daily in `Daily/YYYY-MM-DD.md`, log in `Logs/YYYY-MM-DD.md`.
struct Vault {
    let root: URL
    private var fm: FileManager { .default }

    // MARK: - Lettura

    func clients() -> [VaultClient] {
        let clientiDir = root.appendingPathComponent("Clienti", isDirectory: true)
        var out: [VaultClient] = []
        for group in subdirs(clientiDir) where group.lastPathComponent != "Meetings" {
            for client in subdirs(group) {
                let name = client.lastPathComponent
                guard fm.fileExists(atPath: client.appendingPathComponent("\(name).md").path) else { continue }
                out.append(VaultClient(name: name, group: group.lastPathComponent,
                                       folder: "Clienti/\(group.lastPathComponent)/\(name)"))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Persone collegate al cliente: `referenti` dell'hub + note in `Persone/` che citano [[Cliente]] nel frontmatter.
    func people(for client: VaultClient?) -> [String] {
        let all = allPeople()
        guard let client else { return all }
        var names = Set<String>()
        if let hub = try? String(contentsOf: hubURL(client), encoding: .utf8) {
            for link in Vault.wikilinks(in: Vault.frontmatter(hub)) where all.contains(link) { names.insert(link) }
        }
        let personeDir = root.appendingPathComponent("Persone", isDirectory: true)
        for name in all {
            let file = personeDir.appendingPathComponent("\(name).md")
            if let text = try? String(contentsOf: file, encoding: .utf8),
               Vault.frontmatter(text).contains("[[\(client.name)]]") {
                names.insert(name)
            }
        }
        return names.sorted()
    }

    func allPeople() -> [String] {
        let dir = root.appendingPathComponent("Persone", isDirectory: true)
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
            .sorted()
    }

    func clientFolder(_ c: VaultClient) -> URL { root.appendingPathComponent(c.folder, isDirectory: true) }
    func hubURL(_ c: VaultClient) -> URL { clientFolder(c).appendingPathComponent("\(c.name).md") }

    /// Cartella delle chiamate del cliente: usa quella che esiste (`Chiamate` o `Call`), altrimenti crea `Chiamate`.
    func callsFolder(for client: VaultClient?, unassigned: String) -> URL {
        guard let client else { return root.appendingPathComponent(unassigned, isDirectory: true) }
        let base = clientFolder(client)
        for name in ["Chiamate", "Call", "Calls"] {
            let u = base.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: u.path) { return u }
        }
        return base.appendingPathComponent("Chiamate", isDirectory: true)
    }

    /// `YYYY-MM-DD - Titolo.md`, con suffisso ` (HH-MM)` se esiste già (i nomi file devono essere unici nel vault).
    func newNoteURL(in folder: URL, date: Date, title: String) -> URL {
        let day = Vault.dayFormatter.string(from: date)
        let clean = Vault.sanitize(title)
        var url = folder.appendingPathComponent("\(day) - \(clean).md")
        if fm.fileExists(atPath: url.path) {
            let hm = DateFormatter()
            hm.dateFormat = "HH-mm"
            url = folder.appendingPathComponent("\(day) - \(clean) (\(hm.string(from: date))).md")
        }
        return url
    }

    func relativePath(_ url: URL) -> String {
        let r = root.standardizedFileURL.path, p = url.standardizedFileURL.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }

    // MARK: - Propagazione (solo aggiunte, mai modifiche distruttive)

    /// Aggiunge una riga in fondo alla sezione `## <heading>`; se la sezione non c'è la crea in fondo al file.
    func appendToSection(_ file: URL, heading: String, line: String) throws {
        guard var text = try? String(contentsOf: file, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        if let h = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## \(heading)" }) {
            var end = h + 1
            while end < lines.count, !lines[end].hasPrefix("#") { end += 1 }
            var insertAt = end
            while insertAt > h + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
            lines.insert(line, at: insertAt)
            text = lines.joined(separator: "\n")
        } else {
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n## \(heading)\n\(line)\n"
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Inserisce `line` in fondo alla sezione che inizia alla riga `h` (fino al prossimo titolo di qualunque livello).
    private static func insert(_ line: String, inSectionAt h: Int, of lines: inout [String]) {
        var end = h + 1
        while end < lines.count, !lines[end].hasPrefix("#") { end += 1 }
        var at = end
        while at > h + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
        lines.insert(line, at: at)
    }

    /// index.md: aggiunge la nota nella sezione del cliente (`#### Nome` o `## Nome (Agenzia) - data`),
    /// oppure in `## Inbox/` per le note da smistare.
    @discardableResult
    func appendToIndex(client: String?, line: String) throws -> Bool {
        let file = root.appendingPathComponent("index.md")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        var lines = text.components(separatedBy: "\n")
        let match: (String) -> Bool = { raw in
            guard raw.hasPrefix("#") else { return false }
            let title = raw.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if let client {
                return title == client || title == "[[\(client)]]" || title.hasPrefix("\(client) (")
            }
            return title == "Inbox/" || title == "Inbox"
        }
        guard let h = lines.firstIndex(where: match) else { return false }
        Vault.insert(line, inSectionAt: h, of: &lines)
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    /// Rimuove da index.md solo le righe scritte dall'app che contengono sia `link` sia `marker`.
    func removeIndexLines(containing link: String, marker: String) throws {
        let file = root.appendingPathComponent("index.md")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n")
        let kept = lines.filter { !($0.contains(link) && $0.contains(marker)) }
        if kept.count != lines.count {
            try kept.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Aggiorna in tutto il vault i wikilink a una nota rinominata: [[vecchio]], [[vecchio|alias]], ![[vecchio]].
    func renameLinks(from old: String, to new: String) {
        guard old != new, let e = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        for case let url as URL in e where url.pathExtension == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains("[[\(old)") else { continue }
            let updated = text
                .replacingOccurrences(of: "[[\(old)]]", with: "[[\(new)]]")
                .replacingOccurrences(of: "[[\(old)|", with: "[[\(new)|")
                .replacingOccurrences(of: "[[\(old)#", with: "[[\(new)#")
            if updated != text { try? updated.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    /// Un file della call spostato nel vault dopo la registrazione (a mano o da un agent): lo ritrova dal nome
    /// "YYYY-MM-DD - <Cliente> - <Titolo>", dove di solito cambia solo la parte del cliente. Nil se non è univoco.
    func locateMoved(_ path: String) -> URL? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let parts = name.components(separatedBy: " - ")
        guard parts.count >= 3, let e = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        let prefix = parts[0] + " - ", suffix = " - " + parts.dropFirst(2).joined(separator: " - ")
        var found: [URL] = []
        for case let url as URL in e {
            let n = url.lastPathComponent
            if n.hasPrefix(prefix), n.hasSuffix(suffix), url.path != path { found.append(url) }
        }
        return found.count == 1 ? found[0] : nil
    }

    /// Il cliente nella cui cartella si trova il file.
    func owner(of file: URL) -> VaultClient? {
        clients().first { file.path.hasPrefix(clientFolder($0).path + "/") }
    }

    /// Nel frontmatter di `text` sostituisce i campi `keys` (riga e relativo elenco) con quelli di `source`;
    /// il resto della nota, comprese le modifiche fatte in Obsidian, resta com'è.
    static func replacingFrontmatter(_ keys: [String], in text: String, from source: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let src = source.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---"),
              src.first == "---", let srcClose = src.dropFirst().firstIndex(of: "---") else { return text }
        func block(_ l: [String], _ key: String, _ end: Int) -> Range<Int>? {
            guard let k = l[1..<end].firstIndex(where: { $0.hasPrefix("\(key):") }) else { return nil }
            var e = k + 1
            while e < end, l[e].hasPrefix(" ") || l[e].hasPrefix("-") { e += 1 }
            return k..<e
        }
        var end = close
        for key in keys {
            guard let from = block(src, key, srcClose) else { continue }
            if let to = block(lines, key, end) {
                lines.replaceSubrange(to, with: src[from])
                end += from.count - to.count
            } else {
                lines.insert(contentsOf: src[from], at: end)
                end += from.count
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Nel frontmatter sostituisce un tag (`  - vecchio`) con un altro.
    static func replacingTag(_ old: String, with new: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return text }
        for i in 1..<close where lines[i].trimmingCharacters(in: .whitespaces) == "- \(old)" {
            lines[i] = lines[i].replacingOccurrences(of: "- \(old)", with: "- \(new)")
        }
        return lines.joined(separator: "\n")
    }

    /// Nel registro decisioni del cliente toglie il blocco "## data - titolo" che cita questa nota (scritto dall'app).
    func removeDecisionBlock(client: VaultClient, noteLink: String) throws {
        let file = clientFolder(client).appendingPathComponent("\(client.name) - Decisioni.md")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        guard let src = lines.firstIndex(where: { $0.hasPrefix("Fonte: ") && $0.contains(noteLink) }),
              let start = lines[..<src].lastIndex(where: { $0.hasPrefix("## ") }) else { return }
        var end = src + 1
        while end < lines.count, !lines[end].hasPrefix("## ") { end += 1 }
        // la riga vuota prima del blocco
        let from = start > 0 && lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty ? start - 1 : start
        lines.removeSubrange(from..<end)
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// Rimuove da un file le voci di elenco ("- ...") che contengono `link`: sono le righe aggiunte dall'app.
    func removeListLines(in file: URL, containing link: String) throws {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n")
        let kept = lines.filter { !($0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") && $0.contains(link)) }
        if kept.count != lines.count {
            try kept.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Aggiunge un valore a una lista del frontmatter (inline `[a, b]` o a blocco `- a`); crea la chiave se manca.
    func appendToFrontmatterList(_ file: URL, key: String, value: String) throws {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.hasPrefix("---") else { return }
        var lines = text.components(separatedBy: "\n")
        guard let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return }
        let quoted = "\"\(value)\""
        if let k = lines[1..<close].firstIndex(where: { $0.hasPrefix("\(key):") }) {
            if lines[k].contains(value) { return }
            let rest = lines[k].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("[") && rest.hasSuffix("]") {
                let inner = rest.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                lines[k] = "\(key): [" + (inner.isEmpty ? quoted : "\(inner), \(quoted)") + "]"
            } else if rest.isEmpty {
                var last = k
                while last + 1 < close, lines[last + 1].trimmingCharacters(in: .whitespaces).hasPrefix("- ") { last += 1 }
                if lines[(k + 1)...last].contains(where: { $0.contains(value) }) { return }
                lines.insert("  - \(quoted)", at: last + 1)
            } else {
                return // formato inatteso: non tocchiamo
            }
        } else {
            lines.insert("\(key): [\(quoted)]", at: close)
        }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    func personExists(_ name: String) -> Bool {
        fm.fileExists(atPath: root.appendingPathComponent("Persone/\(name).md").path)
    }

    /// Stub in `Persone/` per una persona nominata con un ruolo (regola "Salvataggio automatico").
    func createPersonStub(name: String, role: String, client: VaultClient, date: Date, sourceNote: String) throws -> URL {
        let dir = root.appendingPathComponent("Persone", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(name).md")
        let day = Vault.dayFormatter.string(from: date)
        let surnameNote = name.contains(" - ") ? " (cognome TBD)" : ""
        let body = """
        ---
        type: persona
        date: \(day)
        tags: [persona]
        ai-first: true
        ruolo: \(role.isEmpty ? "TBD" : role)
        organizzazione: "[[\(client.name)]]"
        clienti: ["[[\(client.name)]]"]
        ultimo_contatto: \(day)
        ---
        # \(name)

        ## For future agent
        \(name.components(separatedBy: " - ").first ?? name)\(surnameNote) è \(role.isEmpty ? "una persona" : role) di [[\(client.name)]] [Inferito]. Emersa nella call registrata del \(day) ([[\(sourceNote)]]): nome e ruolo vengono da una trascrizione automatica, quindi vanno verificati.

        """
        try body.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Catalogo dei clienti per il riconoscimento automatico: nome, agenzia, brand, sito e persone collegate.
    func clientCatalog() -> [(client: VaultClient, details: String)] {
        clients().map { c in
            var parts = ["agenzia: \(c.group)"]
            if let hub = try? String(contentsOf: hubURL(c), encoding: .utf8) {
                let fmText = Vault.frontmatter(hub)
                for key in ["brand", "sito", "settore"] {
                    if let line = fmText.components(separatedBy: "\n").first(where: { $0.hasPrefix("\(key):") }) {
                        let v = line.dropFirst(key.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                        if !v.isEmpty { parts.append("\(key): \(v.prefix(120))") }
                    }
                }
            }
            let people = people(for: c)
            if !people.isEmpty { parts.append("persone: " + people.joined(separator: ", ")) }
            return (c, parts.joined(separator: "; "))
        }
    }

    func appendDaily(date: Date, line: String) throws {
        let dir = root.appendingPathComponent("Daily", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try appendLine(dir.appendingPathComponent("\(Vault.dayFormatter.string(from: date)).md"), line, header: nil)
    }

    func appendLog(date: Date, entries: [String]) throws {
        let dir = root.appendingPathComponent("Logs", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let day = Vault.dayFormatter.string(from: date)
        let header = "---\ntype: log\ndate: \(day)\nai-first: true\n---\n\n# \(day)\n"
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"
        let time = hm.string(from: Date())
        for e in entries {
            try appendLine(dir.appendingPathComponent("\(day).md"), "**\(time)** - \(e)", header: header)
        }
    }

    /// Aggiunge le decisioni a `<Nome> - Decisioni.md` (creato alla prima decisione, append-only).
    func appendDecisions(client: VaultClient, date: Date, title: String, noteName: String, decisions: [String]) throws -> URL {
        let file = clientFolder(client).appendingPathComponent("\(client.name) - Decisioni.md")
        let day = Vault.dayFormatter.string(from: date)
        if !fm.fileExists(atPath: file.path) {
            let slug = client.name.lowercased().replacingOccurrences(of: " ", with: "-")
            let header = """
            ---
            type: decisione
            date: \(day)
            updated: \(day)
            tags: [decisioni, \(slug)]
            ai-first: true
            cliente: "[[\(client.name)]]"
            ---
            # \(client.name) - Decisioni

            ## For future agent
            Registro delle decisioni prese con [[\(client.name)]], in ordine cronologico, con data e fonte. Prima di proporre qualcosa al cliente, controlla qui cosa è già stato deciso.

            """
            try header.write(to: file, atomically: true, encoding: .utf8)
        }
        var block = "\n## \(day) - \(title)\nFonte: [[\(noteName)]] (trascrizione automatica)\n"
        block += decisions.map { "- \($0)" }.joined(separator: "\n") + "\n"
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(block.utf8))
        return file
    }

    private func appendLine(_ file: URL, _ line: String, header: String?) throws {
        if !fm.fileExists(atPath: file.path) {
            try (header ?? "").write(to: file, atomically: true, encoding: .utf8)
        }
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += line + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func subdirs(_ url: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    // MARK: - Utilità

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Nomi file sicuri per Obsidian: niente caratteri speciali né em/en dash (i link si rompono).
    static func sanitize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "–", with: "-")
        t = t.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")).joined(separator: " ")
        t = t.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(t.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    /// Tag Obsidian valido: minuscolo, senza accenti, solo lettere/cifre/-/_ (es. "Acme Viaggi" → acme-viaggi).
    static func tagSlug(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "it_IT")).lowercased()
        var out = ""
        for ch in folded {
            if ch.isLetter || ch.isNumber || ch == "_" { out.append(ch) } else if !out.hasSuffix("-") { out.append("-") }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.contains(where: { $0.isLetter }) ? out : ""
    }

    func replaceInFile(_ file: URL, from old: String, to new: String) throws {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains(old) else { return }
        try text.replacingOccurrences(of: old, with: new).write(to: file, atomically: true, encoding: .utf8)
    }

    /// Sostituisce il testo (es. un link rinominato) nella daily di quel giorno.
    func replaceInDaily(date: Date, from old: String, to new: String) throws {
        let file = root.appendingPathComponent("Daily/\(Vault.dayFormatter.string(from: date)).md")
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains(old) else { return }
        try text.replacingOccurrences(of: old, with: new).write(to: file, atomically: true, encoding: .utf8)
    }

    /// Sostituisce i caratteri vietati dalla regola AI-first (trattini lunghi, virgolette curve, ellissi, ≥ ≤ ≠, nbsp).
    static func asciiSafe(_ s: String) -> String {
        let map: [Character: String] = ["\u{2014}": "-", "\u{2013}": "-", "\u{201C}": "\"", "\u{201D}": "\"",
                                        "\u{2018}": "'", "\u{2019}": "'", "\u{2265}": ">=", "\u{2264}": "<=",
                                        "\u{2260}": "!=", "\u{2026}": "...", "\u{00A0}": " ", "«": "\"", "»": "\""]
        var out = ""
        for ch in s { out += map[ch] ?? String(ch) }
        return out
    }

    static func frontmatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return "" }
        let rest = text.dropFirst(3)
        guard let end = rest.range(of: "\n---") else { return "" }
        return String(rest[..<end.lowerBound])
    }

    static func wikilinks(in text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "[["), let close = rest[open.upperBound...].range(of: "]]") {
            let inner = rest[open.upperBound..<close.lowerBound]
            out.append(String(inner.split(separator: "|").first ?? inner))
            rest = rest[close.upperBound...]
        }
        return out
    }

    /// Link che apre il file in Obsidian.
    static func obsidianURL(for file: URL) -> URL? {
        var c = URLComponents()
        c.scheme = "obsidian"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "path", value: file.path)]
        return c.url
    }
}
