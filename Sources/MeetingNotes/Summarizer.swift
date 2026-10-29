import Foundation

enum SummarizeError: LocalizedError {
    case http(String, Int, String)
    case empty(String)
    case noProvider
    var errorDescription: String? {
        switch self {
        case .http(let p, let code, let body): return "\(p): HTTP \(code) \(body.prefix(300))"
        case .empty(let p): return "\(p): risposta vuota"
        case .noProvider: return "Nessun LLM disponibile (LLM_PROVIDER=none o claude CLI non trovato)."
        }
    }
}

/// Contesto della riunione passato all'LLM.
struct SummaryContext {
    var title: String
    var date: Date
    var client: String?
    var partner: String?
    var participants: [String]
    /// Nomi delle note esistenti nel vault: gli unici che l'LLM può trasformare in [[wikilink]].
    var linkableNames: [String]
    var myNotes: String
    var template: NoteTemplate
    /// false = nota in una cartella normale (niente Obsidian): istruzioni senza vault, Inbox e wikilink.
    var forVault = true
}

/// Genera riepilogo, decisioni e action item (e risponde a domande sulla riunione).
/// Prova i provider in ordine e passa al successivo se uno fallisce.
struct Summarizer {
    let config: Config

    enum Provider: String, CaseIterable { case claude, anthropic, openai, groq, ollama, none }

    /// Contenuto della nota post call (JSON strutturato che compila il template del vault).
    func summarizeCall(transcript: String, context c: SummaryContext, guidance: String) async -> (CallSummary?, String?, [String]) {
        let names = c.linkableNames.isEmpty ? "(nessuno)" : c.linkableNames.map { "[[\($0)]]" }.joined(separator: ", ")
        var extra = ""
        if !c.template.extraSections.isEmpty {
            extra = "\n- Tipo di riunione \"\(c.template.label)\": tra le sezioni includi anche " +
                c.template.extraSections.map { "\"\($0.0)\" (\($0.1))" }.joined(separator: ", ") + "."
        }
        let intro = c.forVault
            ? "Trasformi la trascrizione di una call di lavoro nella nota post call del vault Obsidian di chi l'ha registrata, " +
              "un consulente marketing che lavora per più clienti, direttamente o tramite agenzie partner."
            : "Trasformi la trascrizione di una call di lavoro nella nota di riepilogo per chi l'ha registrata. " +
              "La nota è un file Markdown in una cartella normale: niente Obsidian, niente cartelle da indicare, niente [[wikilink]]."
        let system = """
        \(intro)
        Le righe della trascrizione hanno l'etichetta di chi parla: "\(config.myName)" è chi ha registrato (il suo microfono), \
        "\(config.othersName)" sono tutti gli altri (anche più persone): attribuisci frasi a persone precise solo se è chiaro.

        Istruzioni del template della nota (seguile per contenuto e stile di ogni campo):
        \(guidance)

        Regole:
        - Chi registra si chiama \(config.ownerName): nella nota chiamalo così. Non usare mai le etichette "\(config.myName)" e "\(config.othersName)" nella nota: usa i nomi delle persone quando è chiaro chi parla, altrimenti "il cliente" o "il team".
        - Solo fatti presenti nella trascrizione o negli appunti di chi registra. Mai inventare nomi, numeri, date o decisioni: ciò che non si sa è TBD.
        - Le date restano come sono state dette ("entro giovedì", "a fine mese"): non convertirle in date di calendario.
        - Le sezioni tematiche non ripetono i Next Steps: le azioni future stanno solo in "next_steps".
        - In fondo a ogni elemento di "summary", a ogni punto delle sezioni e a ogni "next_steps" aggiungi il minuto della \
        trascrizione da cui viene l'informazione, tra parentesi quadre come nella trascrizione: es. "... a 1.000 euro al mese. [12:34]". \
        Niente minuti in titolo, obiettivo, partecipanti, for_future_agent e decisioni.
        - Gli appunti di chi registra indicano cosa per lui è importante: assicurati che la nota li copra.
        - La trascrizione è automatica e contiene errori: correggi in silenzio nomi o termini storpiati solo quando il contesto rende certa la parola giusta.
        - \(c.forVault ? "Wikilink: quando citi una di queste note esistenti scrivila esattamente così: \(names). Non creare altri [[wikilink]]." : "Non usare [[wikilink]].")
        - Scrivi in italiano corretto, con gli accenti normali (è, à, perché, lunedì). Sono vietati solo questi caratteri tipografici: trattino lungo o medio (usa "-"), virgolette curve (usa " e '), il carattere unico dei puntini di sospensione (usa "...").\(extra)
        - Scrivi in \(languageName).

        Rispondi SOLO con un oggetto JSON, senza testo prima o dopo e senza blocchi di codice:
        {"titolo": string, "tipo": string, "tag_argomenti": [string], "obiettivo": string|null, "partecipanti": [string],
         "for_future_agent": string, "summary": [string], "sezioni": [{"titolo": string, "punti": [string]}],
         "next_steps": [string], "decisioni": [string]}
        "decisioni": solo le decisioni effettivamente prese in call, una frase ciascuna, con "(stated)" in fondo; [] se nessuna. \
        Non vanno nel corpo della nota: servono per il registro delle decisioni del cliente.
        """
        var user = "Data della call: \(Vault.dayFormatter.string(from: c.date))\n"
        if !c.title.isEmpty { user += "Titolo scelto da chi registra (usalo come titolo): \(c.title)\n" }
        user += "Cliente: \(c.client ?? "non identificato")\n"
        if let p = c.partner {
            user += p == "Diretti" ? "Partner: nessuna agenzia, cliente diretto di \(config.ownerName)\n" : "Partner/agenzia: \(p)\n"
        }
        if !c.participants.isEmpty { user += "Partecipanti dichiarati: \(c.participants.joined(separator: ", "))\n" }
        user += "Tipo di riunione: \(c.template.label)\n"
        if !c.myNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            user += "\n<appunti_di_chi_registra>\n\(c.myNotes)\n</appunti_di_chi_registra>\n"
        }
        user += "\n<trascrizione>\n\(transcript)\n</trascrizione>"

        do {
            let (text, provider) = try await complete(system: system, user: user)
            guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
                  let data = String(text[start...end]).data(using: .utf8) else {
                return (nil, nil, ["\(provider): risposta non in formato JSON"])
            }
            do {
                return (try JSONDecoder().decode(CallSummary.self, from: data), provider, [])
            } catch {
                return (nil, nil, ["\(provider): JSON non valido (\(error.localizedDescription))"])
            }
        } catch let e as MultiError {
            return (nil, nil, e.errors)
        } catch {
            return (nil, nil, [error.localizedDescription])
        }
    }

    /// Domanda libera su una riunione ("Chiedi a Claude").
    func ask(question: String, transcript: String, meeting: Meeting) async throws -> String {
        let system = """
        You answer questions about one meeting, using only its transcript, the summary and the recorder's notes.
        "\(config.myName)" is the person who recorded it (microphone); "\(config.othersName)" is everyone else.
        If the answer is not in the material, say so plainly. Never invent facts. Answer in \(languageName), concisely, in Markdown.
        For every fact, cite the transcript minute it comes from in square brackets, exactly as in the transcript lines, e.g. [12:34].
        """
        var user = "Meeting: \(meeting.title) (\(Vault.dayFormatter.string(from: meeting.date)))\n"
        if let s = meeting.summaryMarkdown { user += "\n<summary>\n\(s)\n</summary>\n" }
        if !meeting.myNotes.isEmpty { user += "\n<recorder_notes>\n\(meeting.myNotes)\n</recorder_notes>\n" }
        user += "\n<transcript>\n\(transcript)\n</transcript>\n\nQuestion: \(question)"
        return Summarizer.clean(try await complete(system: system, user: user).0)
    }

    /// Riconosce di quale cliente del vault parla la call (e le persone nuove nominate con un ruolo).
    func detectClient(transcript: String, title: String, participants: [String], myNotes: String,
                      catalog: [(client: VaultClient, details: String)], knownPeople: [String]) async -> ClientDetection? {
        guard !catalog.isEmpty else { return nil }
        let system = """
        You identify which client a recorded business meeting is about. The person who recorded it ("\(config.myName)") \
        is a marketing consultant who works for several clients, directly or through partner agencies.
        Reply with ONLY a JSON object, no prose, no code fences:
        {"client": <exact client name from the list, or null>,
         "confidence": "high" | "medium" | "low",
         "evidence": <short verbatim quote from the transcript (max 20 words) that identifies the client, or null>,
         "other_clients": [<exact names of other listed clients that are discussed>],
         "unknown_company": <name of the company/brand the meeting is about if it is NOT in the list, else null>,
         "new_people": [{"name": <person name as said>, "role": <their role/job as said>}]}
        Rules:
        - high: the client's name, brand, website or a known person of that client is explicitly mentioned and the meeting is about them.
        - medium: strong indirect evidence (their specific products, services, campaigns, people).
        - low: just a guess. If the meeting is internal or not about any listed client, client = null.
        - The transcript comes from automatic speech recognition: names may be slightly misspelled; match them sensibly.
        - new_people: only people of the client or agency side who are named AND whose role is stated in the meeting, \
        and who are not in the known people list. Use first name and surname if said. When unsure, leave the list empty.
        - Never invent anything that is not in the transcript.
        """
        var user = "Clients in the vault:\n" + catalog.map { "- \($0.client.name) (\($0.details))" }.joined(separator: "\n")
        user += "\n\nKnown people: " + (knownPeople.isEmpty ? "(none)" : knownPeople.joined(separator: ", "))
        user += "\n\nMeeting title: \(title)\n"
        if !participants.isEmpty { user += "Declared participants: \(participants.joined(separator: ", "))\n" }
        if !myNotes.isEmpty { user += "\n<recorder_notes>\n\(myNotes)\n</recorder_notes>\n" }
        user += "\n<transcript>\n\(transcript.prefix(24_000))\n</transcript>"
        guard let (text, _) = try? await complete(system: system, user: user),
              let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let data = String(text[start...end]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ClientDetection.self, from: data)
    }

    /// Domanda su più riunioni insieme. Le riunioni sono numerate [1], [2]…: la risposta le cita così.
    func askAll(question: String, meetings: [Meeting]) async throws -> String {
        let system = """
        You answer questions across several of the user's recorded meetings, using only the notes provided below \
        (summary, decisions, next steps, the recorder's own notes and, when present, transcript excerpts).
        "\(config.ownerName)" is the user (the person who recorded the meetings).
        Rules:
        - Use only the provided material. If the answer is not there, say so plainly. Never invent facts, numbers or dates.
        - Cite the meeting for every fact with its number in square brackets, e.g. [2] or [1][4]. When you know the minute \
        (from a transcript line or a [mm:ss] in the notes), cite it as [2 @ 12:34] instead.
        - When things changed over time, say what changed and when (use the meeting dates).
        - Answer in \(languageName), concisely, in Markdown: short paragraphs, bullets and **bold** only (no tables, no headings deeper than ##).
        """
        var context = ""
        var budget = 180_000
        for (i, m) in meetings.enumerated() {
            var block = "\n### [\(i + 1)] \(m.title)\nData: \(Vault.dayFormatter.string(from: m.date))"
            if let c = m.setup.client { block += " · Cliente: \(c.name)" }
            if !m.setup.participants.isEmpty { block += " · Partecipanti: \(m.setup.participants)" }
            block += "\n"
            if let s = m.summaryMarkdown { block += s + "\n" }
            if !m.myNotes.isEmpty { block += "Appunti di chi registra:\n\(m.myNotes)\n" }
            // Poche riunioni: c'è spazio anche per la trascrizione (più dettagli e citazioni precise).
            if meetings.count <= 4 || m.summaryMarkdown == nil {
                block += "Trascrizione (estratto):\n\(m.transcriptText.prefix(meetings.count <= 4 ? 40_000 : 4_000))\n"
            }
            if block.count > budget { break }
            budget -= block.count
            context += block
        }
        let user = "<meetings>\(context)\n</meetings>\n\nQuestion: \(question)"
        return Summarizer.clean(try await complete(system: system, user: user).0)
    }

    struct MultiError: LocalizedError {
        let errors: [String]
        var errorDescription: String? { errors.joined(separator: "; ") }
    }

    func complete(system: String, user: String) async throws -> (String, String) {
        let providers = await candidates()
        if providers.isEmpty { throw SummarizeError.noProvider }
        var errors: [String] = []
        for provider in providers {
            do {
                let (text, label) = try await run(provider, system: system, user: user)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SummarizeError.empty(provider.rawValue)
                }
                return (text, label)
            } catch {
                NSLog("MeetingNotes: \(provider.rawValue) fallito: \(error.localizedDescription)")
                errors.append("\(provider.rawValue): \(error.localizedDescription)")
            }
        }
        throw MultiError(errors: errors)
    }

    private func candidates() async -> [Provider] {
        if let forced = config["LLM_PROVIDER"].flatMap({ Provider(rawValue: $0.lowercased()) }) {
            return forced == .none ? [] : [forced]
        }
        var list: [Provider] = []
        if config.claudeCLI != nil { list.append(.claude) }
        if config["ANTHROPIC_API_KEY"] != nil { list.append(.anthropic) }
        if config["OPENAI_API_KEY"] != nil { list.append(.openai) }
        if config["GROQ_API_KEY"] != nil { list.append(.groq) }
        // Ollama solo se richiesto esplicitamente (LLM_PROVIDER=ollama) o se non c'è nient'altro.
        if list.isEmpty, await ollamaReachable() { list.append(.ollama) }
        return list
    }

    // MARK: - Lingua

    var languageName: String {
        let code = config.notesLanguage
        if code.hasPrefix("it") { return "italiano" }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    // MARK: - Provider

    private func run(_ p: Provider, system: String, user: String) async throws -> (String, String) {
        switch p {
        case .claude: return try await runClaudeCLI(system: system, user: user)
        case .anthropic:
            let model = config.string("ANTHROPIC_MODEL", default: "claude-sonnet-5-5")
            return (try await anthropic(system: system, user: user, model: model), "Anthropic API \(model)")
        case .openai:
            let model = config.string("OPENAI_MODEL", default: "gpt-4.1-mini")
            return (try await openAICompatible(system: system, user: user, url: "https://api.openai.com/v1/chat/completions",
                                               key: config["OPENAI_API_KEY"] ?? "", model: model, name: "OpenAI"),
                    "OpenAI \(model)")
        case .groq:
            let model = config.string("GROQ_MODEL", default: "llama-3.3-70b-versatile")
            return (try await openAICompatible(system: system, user: user, url: "https://api.groq.com/openai/v1/chat/completions",
                                               key: config["GROQ_API_KEY"] ?? "", model: model, name: "Groq"),
                    "Groq \(model)")
        case .ollama:
            let model = config.string("OLLAMA_MODEL", default: "qwen2.5:14b")
            return (try await ollama(system: system, user: user, model: model), "Ollama \(model) (locale)")
        case .none:
            throw SummarizeError.noProvider
        }
    }

    /// Claude Code in modalità headless: usa il login dell'abbonamento, senza tool, MCP, hook o sessioni salvate.
    private func runClaudeCLI(system: String, user: String) async throws -> (String, String) {
        guard let claude = config.claudeCLI else { throw SummarizeError.empty("Claude Code non trovato: installalo e fai il login una volta con il comando claude nel Terminale (vedi README)") }
        let model = config.string("CLAUDE_MODEL", default: "sonnet")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("meetingnotes-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = try await Shell.run(claude, [
            "-p",
            "--model", model,
            "--output-format", "text",
            "--system-prompt", system,
            "--tools", "",
            "--setting-sources", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence",
        ], input: user, cwd: tmp, env: [
            "DISABLE_TELEMETRY": "1",
            "DISABLE_ERROR_REPORTING": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        ], timeout: 600)
        return (r.stdout, "Claude Code (\(model), abbonamento)")
    }

    private func anthropic(system: String, user: String, model: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        let json = try await postJSON("https://api.anthropic.com/v1/messages", body: body, name: "Anthropic", headers: [
            "x-api-key": config["ANTHROPIC_API_KEY"] ?? "",
            "anthropic-version": "2023-06-01",
        ])
        let content = json["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    }

    private func openAICompatible(system: String, user: String, url: String, key: String, model: String, name: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        let json = try await postJSON(url, body: body, name: name, headers: ["Authorization": "Bearer \(key)"])
        let choices = json["choices"] as? [[String: Any]]
        return (choices?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
    }

    private var ollamaURL: String { config.string("OLLAMA_URL", default: "http://localhost:11434") }

    private func ollama(system: String, user: String, model: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "options": ["num_ctx": 32768, "temperature": 0.2],
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        let json = try await postJSON("\(ollamaURL)/api/chat", body: body, name: "Ollama", headers: [:], timeout: 1800)
        return (json["message"] as? [String: Any])?["content"] as? String ?? ""
    }

    private func ollamaReachable() async -> Bool {
        guard let url = URL(string: "\(ollamaURL)/api/tags") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private func postJSON(_ url: String, body: [String: Any], name: String, headers: [String: String],
                          timeout: TimeInterval = 600) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw SummarizeError.http(name, code, String(decoding: data, as: UTF8.self)) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Toglie eventuali ``` attorno al Markdown e spazi superflui.
    static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
