import Foundation

/// Template della nota post call: si legge dal vault (`Templates/Chiamata - Post call.md`), così modificandolo
/// in Obsidian cambiano le note future. Se nel vault non c'è, si usa una copia interna con la stessa struttura.
struct CallTemplate {
    let text: String

    static let defaultPath = "Templates/Chiamata - Post call.md"

    static func load(config: Config) -> CallTemplate {
        if let root = config.vaultRoot {
            let url = root.appendingPathComponent(config.string("CALL_TEMPLATE_PATH", default: defaultPath))
            if let t = try? String(contentsOf: url, encoding: .utf8), t.contains("{{") { return CallTemplate(text: t) }
        }
        return CallTemplate(text: builtIn)
    }

    /// Istruzioni contenute nei commenti `%% ... %%` del template: vengono passate all'LLM.
    var guidance: String {
        var out: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "%%"), let close = rest[open.upperBound...].range(of: "%%") {
            out.append(String(rest[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[close.upperBound...]
        }
        return out.joined(separator: "\n\n")
    }

    enum Value {
        case text(String)
        case list([String])
        case markdown(String)   // blocco già formattato (es. le sezioni)
    }

    /// Compila i segnaposto. Le righe "  - {{x}}" / "  - tag_x" diventano un elemento per valore;
    /// un valore mancante diventa TBD (o la riga sparisce, per le liste).
    func render(_ values: [String: Value]) -> String {
        var body = text
        // Via i commenti %% ... %% (istruzioni del template).
        while let open = body.range(of: "%%"), let close = body[open.upperBound...].range(of: "%%") {
            var end = close.upperBound
            while end < body.endIndex, body[end] == "\n" { end = body.index(after: end) }
            body.removeSubrange(open.lowerBound..<end)
        }

        var lines: [String] = []
        var inFrontmatter = false
        var frontmatterDone = false
        for (i, line) in body.components(separatedBy: "\n").enumerated() {
            if line.trimmingCharacters(in: .whitespaces) == "---" && !frontmatterDone {
                if i == 0 { inFrontmatter = true } else if inFrontmatter { inFrontmatter = false; frontmatterDone = true }
                lines.append(line)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = String(line.prefix(while: { $0 == " " }))

            // Elemento di lista con segnaposto: "  - {{chiave}}" oppure "  - tag_chiave"
            if trimmed.hasPrefix("- ") {
                let token = String(trimmed.dropFirst(2))
                let key: String? = token.hasPrefix("{{") && token.hasSuffix("}}") ? String(token.dropFirst(2).dropLast(2))
                    : token.hasPrefix("tag_") ? token : nil
                if let key {
                    let items: [String]
                    switch values[key] {
                    case .list(let l)?: items = l
                    case .text(let t)?: items = t.isEmpty ? [] : [t]
                    default: items = []
                    }
                    let cleaned = items.map { inFrontmatter ? CallTemplate.oneLine(Vault.asciiSafe($0)) : Vault.asciiSafe($0) }.filter { !$0.isEmpty }
                    if inFrontmatter {
                        lines += cleaned.map { "\(indent)- \(key.hasPrefix("tag_") ? $0 : CallTemplate.yamlQuote($0))" }
                    } else {
                        lines += cleaned.map { "\(indent)- \($0)" }
                    }
                    continue
                }
            }
            lines.append(inFrontmatter ? fillFrontmatter(line, values) : fillBody(line, values))
        }
        return lines.joined(separator: "\n")
    }

    private func fillFrontmatter(_ line: String, _ values: [String: Value]) -> String {
        var out = line
        for key in placeholders(in: line) {
            let raw = textValue(values[key])
            let token = "{{\(key)}}"
            // Dentro un wikilink tra virgolette: senza valore, tutto il campo diventa TBD.
            if out.contains("\"[[\(token)]]\"") {
                out = out.replacingOccurrences(of: "\"[[\(token)]]\"", with: raw.map { "\"[[\($0)]]\"" } ?? "TBD")
            } else if out.trimmingCharacters(in: .whitespaces).hasSuffix(": \(token)") {
                out = out.replacingOccurrences(of: token, with: raw.map(CallTemplate.yamlQuote) ?? "TBD")
            } else {
                out = out.replacingOccurrences(of: token, with: raw ?? "TBD")
            }
        }
        return out
    }

    private func fillBody(_ line: String, _ values: [String: Value]) -> String {
        var out = line
        for key in placeholders(in: line) {
            let token = "{{\(key)}}"
            let replacement: String
            switch values[key] {
            case .list(let l)?: replacement = l.map { "- \(Vault.asciiSafe($0))" }.joined(separator: "\n\n")
            case .markdown(let m)?: replacement = Vault.asciiSafe(m)
            case .text(let t)?: replacement = Vault.asciiSafe(t)
            case nil: replacement = "TBD"
            }
            out = out.replacingOccurrences(of: token, with: replacement)
        }
        return out
    }

    private func textValue(_ v: Value?) -> String? {
        switch v {
        case .text(let t)?: return t.isEmpty ? nil : CallTemplate.oneLine(Vault.asciiSafe(t))
        case .list(let l)?: return l.isEmpty ? nil : CallTemplate.oneLine(Vault.asciiSafe(l.joined(separator: ", ")))
        case .markdown(let m)?: return Vault.asciiSafe(m)
        case nil: return nil
        }
    }

    private func placeholders(in line: String) -> [String] {
        var keys: [String] = []
        var rest = Substring(line)
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            keys.append(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return keys
    }

    /// Nel frontmatter un a-capo romperebbe lo YAML.
    static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Stringa YAML tra virgolette quando serve (due punti, cancelletto, apici iniziali...).
    static func yamlQuote(_ s: String) -> String {
        let needs = s.contains(": ") || s.contains(" #") || s.hasPrefix("[") || s.hasPrefix("{") || s.hasPrefix("\"")
            || s.hasPrefix("'") || s.hasPrefix("*") || s.hasPrefix("&") || s.hasPrefix("!") || s.hasPrefix("%") || s.hasPrefix("@")
        guard needs else { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Copia interna (stessa struttura del template del vault, senza le istruzioni).
    /// Istruzioni per chi salva le note in una cartella normale, senza Obsidian.
    static let plainGuidance = """
    Campi da compilare leggendo la call:
    - titolo: titolo descrittivo della call, massimo 8 parole, senza data. Es. "Kickoff progetto sito", "Revisione budget Q4".
    - tipo: una sola parola tra onboarding, operativa, conoscitiva, strategia, report, interna, altro.
    - tag_argomenti: da 1 a 4 parole chiave in kebab-case sugli argomenti (es. budget, sito-web, assunzioni).
    - partecipanti: un elemento per persona, nel modo in cui viene nominata; ruolo o note tra parentesi. Chi non è identificabile: "altri partecipanti (nomi non registrati)".
    - obiettivo: l'obiettivo dichiarato nella call, breve, con numeri e scadenze se detti. Altrimenti TBD.
    - for_future_agent: 2-3 frasi di contesto: di che call si tratta, con chi, i temi principali con i numeri chiave in **grassetto**.
    - summary: 2-3 bullet con le cose essenziali da sapere.
    - sezioni: da 3 a 6 sezioni tematiche, ognuna con un titolo descrittivo e 2-4 bullet. Frasi complete in forma impersonale ("È stato deciso...", "Viene utilizzata..."), termini tecnici tra `backtick`, nessun fatto inventato.
    - next_steps: chi farà cosa e quando, solo se detto nella call.
    """

    static let builtIn = """
    ---
    type: chiamata
    date: {{data}}
    updated: {{data}}
    tags:
      - chiamata
      - tag_tipo
      - tag_cliente
      - tag_argomenti
    ai-first: true
    cliente: "[[{{cliente}}]]"
    partner: "[[{{partner}}]]"
    stato: {{stato}}
    data_call: {{data_call}}
    partecipanti:
      - {{partecipanti}}
    obiettivo: {{obiettivo}}
    collegata_a:
      - {{collegata_a}}
    ---

    ## For future agent
    {{for_future_agent}}

    - Created: {{created}}

    ## Summary

    {{summary}}

    {{sezioni}}

    # Next Steps

    {{next_steps}}

    """
}
