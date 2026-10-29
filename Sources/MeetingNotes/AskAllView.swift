import SwiftUI

/// "Chiedi a tutte le riunioni": domande su più call insieme, con filtro per cliente e periodo
/// e citazioni cliccabili delle riunioni usate.
struct AskAllView: View {
    @ObservedObject var state: AppState
    @ObservedObject var selection: ArchiveSelection
    @ViewState private var client: String = ""
    @ViewState private var days: Int = 90
    @ViewState private var question = ""
    @ViewState private var history: [Exchange] = []
    @ViewState private var busy = false
    @FocusState private var focused: Bool

    struct Exchange {
        let question: String
        let answer: String
        let sources: [Meeting]   // nell'ordine della numerazione [1], [2]…
    }

    private let periods: [(Int, String)] = [(7, "Ultimi 7 giorni"), (30, "Ultimi 30 giorni"), (90, "Ultimi 3 mesi"), (0, "Tutte")]

    private var scope: [Meeting] {
        let since = days > 0 ? Calendar.current.date(byAdding: .day, value: -days, to: Date()) : nil
        return state.meetings.filter { m in
            (client.isEmpty || m.setup.client?.name == client) && (since.map { m.date >= $0 } ?? true) && !m.segments.isEmpty
        }
    }

    private var clientNames: [String] { Array(Set(state.meetings.compactMap { $0.setup.client?.name })).sorted() }

    private let suggestions = [
        ("checklist", "Quali action item sono ancora aperti e di chi sono?"),
        ("arrow.triangle.branch", "Quali decisioni sono state prese, in ordine di data?"),
        ("eurosign", "Quali budget e numeri sono stati citati?"),
        ("exclamationmark.bubble", "Quali problemi o obiezioni sono emersi più spesso?"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 14)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if history.isEmpty { intro }
                        ForEach(Array(history.enumerated()), id: \.offset) { i, ex in
                            exchange(ex, first: i == 0).id(i)
                        }
                        if busy {
                            HStack(spacing: Theme.Space.s) {
                                ProgressView().controlSize(.small)
                                Text(scope.count == 1 ? "Claude sta leggendo la riunione…" : "Claude sta leggendo \(scope.count) riunioni…").foregroundStyle(.secondary)
                            }
                            .padding(.vertical, Theme.Space.l)
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: history.count) { withAnimation { proxy.scrollTo(history.count - 1, anchor: .bottom) } }
            }
            .background(Theme.canvas)
            AskInputBar(placeholder: "Chiedi qualcosa su queste riunioni…", text: $question, focused: $focused,
                        canSend: canSend) { ask(question) }
        }
        // Citazioni [2] / [2 @ 12:34]: aprono quella riunione (e partono da quel minuto).
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "mn-open", let id = url.host else { return url.scheme == "mn-seek" ? .handled : .systemAction }
            let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "t" }?.value.flatMap(Double.init)
            selection.pendingSeek = t
            selection.id = id
            return .handled
        })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chiedi a tutte le riunioni")
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.3)
                .lineLimit(1)
            HStack(spacing: 8) {
                Menu {
                    Button("Tutti i clienti") { client = "" }
                    Divider()
                    ForEach(clientNames, id: \.self) { name in Button(name) { client = name } }
                } label: { Text(client.isEmpty ? "Tutti i clienti" : client) }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Cliente")
                Text("·").foregroundStyle(.tertiary)
                Menu {
                    ForEach(periods, id: \.0) { p in Button(p.1) { days = p.0 } }
                } label: { Text(periods.first { $0.0 == days }?.1 ?? "") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Periodo")
                Text("·").foregroundStyle(.tertiary)
                Text(scope.isEmpty ? "Nessuna riunione in questo filtro" : scope.count == 1 ? "Claude userà 1 riunione" : "Claude userà \(scope.count) riunioni")
                    .foregroundStyle(scope.isEmpty ? Theme.warning : Color.secondary)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Domande che attraversano più call: Claude risponde citando le riunioni da cui prende ogni informazione.")
                .foregroundStyle(.secondary)
                .padding(.bottom, Theme.Space.m)
            ForEach(Array(suggestions.enumerated()), id: \.offset) { i, s in
                if i == 0 { Hairline() }
                HoverRow(action: { ask(s.1) }) {
                    Image(systemName: s.0).foregroundStyle(Theme.brand).frame(width: 18)
                    Text(s.1).font(.system(size: 14))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                }
                .disabled(scope.isEmpty)
                Hairline()
            }
        }
    }

    private func exchange(_ ex: Exchange, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AnswerBlock(question: ex.question, answer: ex.answer, first: first,
                        answerText: Timestamps.linkifyMulti(ex.answer, sources: ex.sources))
            let cited = citedSources(ex)
            if !cited.isEmpty {
                RuledLabel(text: "Fonti").padding(.bottom, 2)
                ForEach(cited, id: \.0) { n, m in
                    HoverRow(action: { selection.id = m.id }) {
                        Text("[\(n)]").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.brand)
                        Text(m.title).font(.system(size: 13.5)).lineLimit(1)
                        Spacer()
                        Text(Vault.dayFormatter.string(from: m.date)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .help("Apri la riunione")
                    Hairline().opacity(0.6)
                }
            }
        }
        .padding(.bottom, Theme.Space.m)
    }

    /// Le riunioni citate nella risposta come [n].
    private func citedSources(_ ex: Exchange) -> [(Int, Meeting)] {
        var out: [(Int, Meeting)] = []
        for (i, m) in ex.sources.enumerated() where ex.answer.contains("[\(i + 1)]") {
            out.append((i + 1, m))
        }
        return out
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !busy && !scope.isEmpty
    }

    private func ask(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy, !scope.isEmpty else { return }
        question = ""
        busy = true
        let sources = scope   // già dalla più recente
        Task {
            let answer: String
            do {
                answer = try await Summarizer(config: state.config).askAll(question: q, meetings: sources)
            } catch {
                answer = "**Non è stato possibile rispondere.** \(error.localizedDescription)"
            }
            history.append(Exchange(question: q, answer: answer, sources: sources))
            busy = false
        }
    }
}
