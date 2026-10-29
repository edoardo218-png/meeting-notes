import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Archivio

struct ArchiveView: View {
    @ObservedObject var state: AppState
    @ObservedObject var selection: ArchiveSelection
    @ViewState private var search = ""
    @ViewState private var clientFilter: String?
    @ViewState private var pendingDelete: Meeting?

    private var filtered: [Meeting] {
        state.meetings.filter { m in
            if let clientFilter {
                if clientFilter == ArchiveView.inboxFilter { if m.setup.client != nil || !m.inVault { return false } }
                else if m.setup.client?.name != clientFilter { return false }
            }
            guard !search.isEmpty else { return true }
            let q = search.lowercased()
            return m.title.lowercased().contains(q)
                || (m.setup.client?.name.lowercased().contains(q) ?? false)
                || m.setup.participants.lowercased().contains(q)
                || (m.summaryMarkdown?.lowercased().contains(q) ?? false)
                || m.myNotes.lowercased().contains(q)
                || m.segments.contains { $0.text.lowercased().contains(q) }
        }
    }

    static let inboxFilter = "__inbox__"
    static let askAllID = "__ask_all__"

    private var clientNames: [String] {
        Array(Set(state.meetings.compactMap { $0.setup.client?.name })).sorted()
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 270, ideal: 310)
        } detail: {
            if selection.id == ArchiveView.askAllID {
                AskAllView(state: state, selection: selection)
            } else if let id = selection.id, let m = state.meetings.first(where: { $0.id == id }) {
                MeetingDetailView(state: state, meeting: m, onDelete: { pendingDelete = m })
                    .id(m.id + m.audioPath)
            } else {
                emptyState
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { importAudio() } label: { Label("Importa audio", systemImage: "square.and.arrow.down") }
                    .help("Trascrivi e riassumi un file audio esistente")
                Button {
                    Task { await state.prepareDraft(); WindowManager.shared.showPanel() }
                } label: { Label("Nuova registrazione", systemImage: "record.circle") }
                    .help("Nuova registrazione")
                    .disabled(state.phase != .idle)
            }
        }
        .toolbar(removing: .title)   // il titolo grande è già nel dettaglio
        .onAppear {
            if selection.id == nil { selection.id = state.meetings.first?.id }
        }
        .confirmationDialog("Eliminare \"\(pendingDelete?.title ?? "")\"?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { m in
            Button("Elimina solo dall'app") { remove(m, files: false) }
            Button(m.inVault ? "Elimina anche dal vault (nel Cestino)" : "Elimina anche i file (nel Cestino)", role: .destructive) {
                remove(m, files: true)
            }
            Button("Annulla", role: .cancel) {}
        } message: { m in
            Text(m.inVault
                 ? "\"Solo dall'app\" la toglie dall'archivio e lascia nota, trascrizione e audio nel vault. \"Anche dal vault\" sposta i file nel Cestino (recuperabili) e toglie le righe aggiunte a index, hub e daily; il registro delle decisioni resta."
                 : "\"Anche i file\" sposta nota e audio nel Cestino (recuperabili).")
        }
    }

    // MARK: Elenco

    private var sidebar: some View {
        List(selection: $selection.id) {
            Label("Chiedi a tutte le riunioni", systemImage: "sparkles")
                .font(.body.weight(.medium))
                .padding(.vertical, 2)
                .tag(ArchiveView.askAllID)
            if !state.processing.isEmpty {
                Section("In elaborazione") {
                    ForEach(state.processing.sorted { $0.key < $1.key }, id: \.key) { item in
                        HStack(spacing: Theme.Space.s) {
                            ProgressView().controlSize(.small)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(processingTitle(item.key)).font(.callout.weight(.medium)).lineLimit(1)
                                Text(item.value).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .selectionDisabled()
                    }
                }
            }
            ForEach(sections, id: \.0) { title, meetings in
                Section(title) {
                    ForEach(meetings) { m in
                        MeetingRow(meeting: m)
                            .tag(m.id)
                            .contextMenu {
                                Button { NoteOpener.open(m) } label: { Label(m.inVault ? "Apri in Obsidian" : "Apri nota", systemImage: "doc.text") }
                                Button { NSWorkspace.shared.activateFileViewerSelecting([m.noteURL]) } label: { Label("Mostra nel Finder", systemImage: "folder") }
                                Divider()
                                Button(role: .destructive) { pendingDelete = m } label: { Label("Elimina…", systemImage: "trash") }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Cerca in titoli, note e trascrizioni")
        .onDeleteCommand {
            if let id = selection.id, id != ArchiveView.askAllID { pendingDelete = state.meetings.first { $0.id == id } }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Tutte le riunioni") { clientFilter = nil }
                    Button("Da smistare") { clientFilter = ArchiveView.inboxFilter }
                    Divider()
                    ForEach(clientNames, id: \.self) { name in Button(name) { clientFilter = name } }
                } label: {
                    Label(filterLabel, systemImage: clientFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .help("Filtra per cliente")
            }
        }
    }

    private var filterLabel: String {
        switch clientFilter {
        case nil: return "Filtra"
        case ArchiveView.inboxFilter?: return "Da smistare"
        case let c?: return c
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.l) {
            BrandMark(size: 56)
            VStack(spacing: Theme.Space.xs) {
                Text(state.meetings.isEmpty ? "Ancora nessuna riunione" : "Seleziona una riunione").font(.system(size: 22, weight: .bold))
                Text("Avvia una registrazione con ⌃⌥⌘R o dal menu nella barra in alto.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Theme.Space.s) {
                Button {
                    Task { await state.prepareDraft(); WindowManager.shared.showPanel() }
                } label: { Label("Nuova registrazione", systemImage: "record.circle") }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brandFill)
                Button { importAudio() } label: { Label("Importa un file audio", systemImage: "square.and.arrow.down") }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    /// Raggruppa per giorno: Oggi, Ieri, poi data.
    private var sections: [(String, [Meeting])] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEEE d MMMM yyyy"
        var out: [(String, [Meeting])] = []
        for m in filtered {
            let title = cal.isDateInToday(m.date) ? "Oggi" : cal.isDateInYesterday(m.date) ? "Ieri" : f.string(from: m.date).capitalized(with: Locale(identifier: "it_IT"))
            if let i = out.firstIndex(where: { $0.0 == title }) { out[i].1.append(m) } else { out.append((title, [m])) }
        }
        return out
    }

    /// "2026-10-09-1500" → "Registrazione delle 15:00"; altrimenti il nome del file importato.
    private func processingTitle(_ key: String) -> String {
        if let d = Pipeline.stampFormatter.date(from: String(key.prefix(15))) {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return "Registrazione delle \(f.string(from: d))"
        }
        return key
    }

    private func remove(_ m: Meeting, files: Bool) {
        let list = filtered
        if selection.id == m.id {
            let i = list.firstIndex(where: { $0.id == m.id }) ?? 0
            let next = list.indices.contains(i + 1) ? list[i + 1] : (i > 0 ? list[i - 1] : nil)
            selection.id = next?.id
        }
        state.delete(m, deleteFiles: files)
        pendingDelete = nil
    }

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach(state.importAudio) }
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            HStack(spacing: 5) {
                Text(meeting.date, format: .dateTime.hour().minute()).monospacedDigit()
                Text("·")
                Text("\(max(1, Int(meeting.durationSeconds / 60))) min")
                if meeting.summaryMarkdown == nil && !meeting.segments.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(prominence == .increased ? .white : Theme.warning)
                        .help("Nota non ancora generata")
                        .accessibilityLabel("Nota non ancora generata")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            ClientBadge(meeting: meeting)
        }
        .padding(.vertical, 4)
    }
}

/// Cliente (o "Da smistare") come testo colorato, con ✦ se riconosciuto automaticamente.
struct ClientBadge: View {
    let meeting: Meeting
    /// Sulla riga selezionata (sfondo colore accento) il colore non si legge: lì il testo diventa bianco.
    @Environment(\.backgroundProminence) private var prominence
    private var onSelection: Bool { prominence == .increased }

    var body: some View {
        if let c = meeting.setup.client {
            Label(c.name, systemImage: meeting.setup.clientSource == "automatico" ? "sparkles" : "building.2")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(onSelection ? .white : Theme.brand)
                .labelStyle(TightLabel())
                .help(meeting.setup.clientSource == "automatico" ? "Cliente riconosciuto automaticamente dal contenuto della call" : c.group)
        } else if meeting.inVault {
            Label("Da smistare", systemImage: "tray")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(onSelection ? .white : Theme.warning)
                .labelStyle(TightLabel())
                .help("Cliente non riconosciuto: la nota è in Inbox")
        }
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.imageScale(.small); configuration.title }
    }
}

// MARK: - Dettaglio

struct MeetingDetailView: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    var onDelete: () -> Void = {}
    @StateObject private var player: PlayerModel
    @ViewState private var tab = Tab.note
    @ViewState private var confirmRegenerate = false
    @ViewState private var editing = false
    @ViewState private var editingTitle = false
    @ViewState private var titleDraft = ""
    @ViewState private var titleHover = false
    @FocusState private var titleFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Tab: String, CaseIterable { case note = "Nota", transcript = "Trascrizione", ask = "Chiedi a Claude" }

    init(state: AppState, meeting: Meeting, onDelete: @escaping () -> Void = {}) {
        self.state = state
        self.meeting = meeting
        self.onDelete = onDelete
        _player = StateObject(wrappedValue: PlayerModel(url: meeting.audioURL))
    }

    private var busy: Bool { state.processing[meeting.id] != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 14)
            EditorialTabs(items: Tab.allCases.map { ($0, $0.rawValue) }, selection: $tab)
                .padding(.horizontal, 28)
            Hairline()
            Group {
                switch tab {
                case .note: noteView
                case .transcript: TranscriptView(turns: Merge.turns(meeting.segments), player: player, myName: state.config.myName)
                case .ask: AskView(state: state, meeting: meeting)
                }
            }
            .id(tab)
            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 6)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
            PlayerBar(player: player)
        }
        // Minuti nel testo ([12:34]): un clic fa partire l'audio da lì.
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "mn-seek", let t = Double(url.host ?? "") {
                player.seek(to: t, play: true)
                return .handled
            }
            return .systemAction
        })
        .onAppear {
            // Aperta da una citazione in "Chiedi a tutte le riunioni": parte dal minuto citato.
            if let t = WindowManager.shared.archiveSelection.pendingSeek {
                WindowManager.shared.archiveSelection.pendingSeek = nil
                player.seek(to: t, play: true)
            }
        }
        .sheet(isPresented: $editing) { EditMeetingSheet(state: state, meeting: meeting) }
        .confirmationDialog("Rigenerare la nota?", isPresented: $confirmRegenerate) {
            Button("Rigenera") { state.regenerate(meeting) }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Claude riscrive la nota da capo: eventuali modifiche fatte a mano in Obsidian andranno perse.")
        }
    }

    // MARK: Testata

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                titleView
                Spacer(minLength: Theme.Space.m)
                if let status = state.processing[meeting.id] {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { NoteOpener.open(meeting) } label: {
                    Label(meeting.inVault ? "Apri in Obsidian" : "Apri nota", systemImage: "arrow.up.forward")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brandFill)
                .controlSize(.regular)
                moreMenu
            }
            metaLine
            if let stats = TalkStats.from(meeting.segments, myName: state.config.myName, othersName: state.config.othersName),
               stats.total > 10 {
                TalkStatsView(stats: stats)
            }
        }
    }

    /// Titolo grande su una riga; doppio clic (o la matita) per rinominare, senza rifare il riassunto.
    @ViewBuilder private var titleView: some View {
        if editingTitle {
            TextField("Titolo", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .bold))
                .focused($titleFocused)
                .onSubmit { commitTitle() }
                .onExitCommand { editingTitle = false }
                .onAppear { titleFocused = true }
        } else {
            HStack(spacing: Theme.Space.s) {
                Text(meeting.title)
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(meeting.title)
                if titleHover && !busy {
                    Button { startTitleEdit() } label: { Image(systemName: "pencil").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .help("Rinomina (non rifà il riassunto)")
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if !busy { startTitleEdit() } }
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { titleHover = h } }
        }
    }

    private func startTitleEdit() {
        titleDraft = meeting.title
        editingTitle = true
    }

    private func commitTitle() {
        editingTitle = false
        let t = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != meeting.title else { return }
        var m = meeting
        m.setup.title = t
        state.updateDetails(m)
    }

    /// Data · durata · cliente (menu) · tipo (menu) · partecipanti. Cliente e tipo si cambiano da qui, all'istante.
    private var metaLine: some View {
        HStack(spacing: 8) {
            Text(meeting.date, format: .dateTime.weekday(.wide).day().month(.wide).hour().minute())
            dot
            Text("\(max(1, Int(meeting.durationSeconds / 60))) min").monospacedDigit()
            if meeting.inVault {
                dot
                clientMenu
            }
            dot
            Menu {
                ForEach(NoteTemplate.allCases) { t in
                    Button { var m = meeting; m.setup.template = t; state.updateDetails(m) } label: {
                        if t == meeting.setup.template { Label(t.label, systemImage: "checkmark") } else { Text(t.label) }
                    }
                }
            } label: { Text(meeting.setup.template.label) }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(busy)
                .help("Tipo di riunione (non rifà il riassunto)")
            if !meeting.setup.participants.isEmpty {
                dot
                Text(meeting.setup.participants).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
    }

    private var dot: some View { Text("·").foregroundStyle(.tertiary) }

    private var clientMenu: some View {
        let groups = Array(Set(state.clients.map(\.group))).sorted()
        return Menu {
            Button { assign(nil) } label: {
                if meeting.setup.client == nil { Label("Nessuno (Inbox, da smistare)", systemImage: "checkmark") }
                else { Text("Nessuno (Inbox, da smistare)") }
            }
            ForEach(groups, id: \.self) { g in
                Section(g) {
                    ForEach(state.clients.filter { $0.group == g }) { c in
                        Button { assign(c) } label: {
                            if c == meeting.setup.client { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                        }
                    }
                }
            }
        } label: {
            if let c = meeting.setup.client {
                Label(c.name, systemImage: meeting.setup.clientSource == "automatico" ? "sparkles" : "building.2")
                    .labelStyle(TightLabel())
                    .foregroundStyle(Theme.brand)
            } else {
                Label("Da smistare", systemImage: "tray").labelStyle(TightLabel()).foregroundStyle(Theme.warning)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(busy)
        .help("Cliente: sposta la nota nella sua cartella (non rifà il riassunto)")
        .onAppear { if state.clients.isEmpty { state.reloadVault() } }
    }

    private func assign(_ c: VaultClient?) {
        guard c != meeting.setup.client else { return }
        var m = meeting
        m.setup.client = c
        m.setup.clientSource = "manuale"
        state.updateDetails(m)
    }

    private var moreMenu: some View {
        Menu {
            Button { editing = true } label: { Label("Modifica dettagli…", systemImage: "pencil") }
            Button { confirmRegenerate = true } label: { Label("Rigenera la nota con Claude", systemImage: "arrow.clockwise") }
            Divider()
            Button { copy(meeting.summaryMarkdown ?? "") } label: { Label("Copia la nota", systemImage: "doc.on.doc") }
            Button { copy(meeting.transcriptText) } label: { Label("Copia la trascrizione", systemImage: "text.quote") }
            Divider()
            Button { NSWorkspace.shared.activateFileViewerSelecting([meeting.noteURL]) } label: { Label("Mostra nota nel Finder", systemImage: "folder") }
            Button { NSWorkspace.shared.activateFileViewerSelecting([meeting.audioURL]) } label: { Label("Mostra audio nel Finder", systemImage: "waveform") }
            Divider()
            Button(role: .destructive) { onDelete() } label: { Label("Elimina riunione…", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Altre azioni")
        .accessibilityLabel("Altre azioni")
        .disabled(busy)
    }

    // MARK: Nota

    private var noteView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let summary = meeting.summaryMarkdown {
                    MarkdownView(text: Timestamps.annotate(summary, turns: Merge.turns(meeting.segments)))
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(meeting.segments.isEmpty ? "Nessun parlato rilevato" : "Nota non ancora generata",
                              systemImage: meeting.segments.isEmpty ? "waveform.slash" : "exclamationmark.triangle")
                            .font(.system(size: 17, weight: .semibold))
                        if !meeting.segments.isEmpty {
                            Text("La trascrizione è salvata: la nota si può generare adesso.").foregroundStyle(.secondary)
                            Button { state.regenerate(meeting) } label: { Label("Genera la nota", systemImage: "sparkles") }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.brandFill)
                        }
                    }
                    .padding(.top, Theme.Space.s)
                }
                if !meeting.myNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        RuledLabel(text: "I miei appunti")
                        Text(meeting.myNotes).font(.system(size: 14)).textSelection(.enabled).lineSpacing(4)
                    }
                    .padding(.top, Theme.Space.s)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Quanto parli tu

struct TalkStatsView: View {
    let stats: TalkStats
    @ViewState private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var percent: Int { Int((stats.meShare * 100).rounded()) }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text("Hai parlato il \(percent)%").font(.system(size: 12.5, weight: .semibold))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.others.opacity(0.85))
                    Capsule().fill(Theme.me)
                        .frame(width: max(3, geo.size.width * (shown ? stats.meShare : 0)))
                }
            }
            .frame(width: 180, height: 4)
            Text("Tu \(minutes(stats.me)) · Altri \(minutes(stats.others)) · intervento più lungo \(Merge.timestamp(stats.longestMe))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .onAppear {
            if reduceMotion { shown = true }
            else { withAnimation(.easeOut(duration: 0.6).delay(0.1)) { shown = true } }
        }
        .help("Calcolato dalle due tracce: il tuo microfono (Tu) e l'audio della call (Altri).")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hai parlato il \(percent) per cento: tu \(minutes(stats.me)), altri \(minutes(stats.others))")
    }

    private func minutes(_ s: Double) -> String {
        s < 60 ? "\(Int(s.rounded())) s" : "\(Int((s / 60).rounded())) min"
    }
}

// MARK: - Trascrizione

struct TranscriptView: View {
    let turns: [Merge.Turn]
    @ObservedObject var player: PlayerModel
    let myName: String
    @ViewState private var follow = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentID: Double? {
        turns.last(where: { $0.start <= player.time + 0.3 })?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(turns.enumerated()), id: \.element.id) { i, turn in
                        if i > 0 && turns[i - 1].speaker != turn.speaker { Hairline().opacity(0.6) }
                        row(turn, isCurrent: player.isPlaying && turn.id == currentID)
                            .id(turn.id)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: currentID) {
                guard follow, player.isPlaying, let id = currentID else { return }
                if reduceMotion { proxy.scrollTo(id, anchor: .center) }
                else { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .overlay(alignment: .topTrailing) {
            Toggle("Segui l'audio", isOn: $follow)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .padding(Theme.Space.m)
        }
        .overlay {
            if turns.isEmpty {
                Label("Nessun parlato rilevato", systemImage: "waveform.slash").foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ turn: Merge.Turn, isCurrent: Bool) -> some View {
        let isMe = turn.speaker == myName
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            Button(Merge.timestamp(turn.start)) { player.seek(to: turn.start, play: true) }
                .buttonStyle(.plain)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(isCurrent ? Theme.brand : Color.secondary)
                .frame(width: 44, alignment: .leading)
                .help("Ascolta da qui")
                .accessibilityLabel("Ascolta da \(Merge.timestamp(turn.start))")
            VStack(alignment: .leading, spacing: 3) {
                Text((turn.speaker.isEmpty ? "Audio" : turn.speaker).uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(isMe ? Theme.me : Theme.others)
                Text(turn.text).font(.system(size: 14)).textSelection(.enabled).lineSpacing(4)
            }
        }
        .padding(.vertical, 12)
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.brand).frame(width: 2).opacity(isCurrent ? 1 : 0)
        }
        .background(isCurrent ? Theme.brandSoft.opacity(0.6) : Color.clear)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isCurrent)
    }
}

// MARK: - Chiedi a Claude

struct AskView: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    @ViewState private var question = ""
    @ViewState private var history: [(q: String, a: String)] = []
    @ViewState private var busy = false
    @FocusState private var focused: Bool

    private let suggestions = [
        ("envelope", "Scrivi una mail di follow-up per il cliente"),
        ("number", "Quali numeri e cifre sono stati citati?"),
        ("questionmark.bubble", "Cosa mi ha chiesto esplicitamente il cliente?"),
        ("hourglass", "Quali punti sono rimasti in sospeso?"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if history.isEmpty { intro }
                        ForEach(Array(history.enumerated()), id: \.offset) { i, item in
                            AnswerBlock(question: item.q, answer: item.a, first: i == 0)
                                .id(i)
                        }
                        if busy {
                            HStack(spacing: Theme.Space.s) {
                                ProgressView().controlSize(.small)
                                Text("Claude sta leggendo la riunione…").foregroundStyle(.secondary)
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
            AskInputBar(placeholder: "Chiedi qualcosa su questa riunione…", text: $question, focused: $focused,
                        canSend: canSend) { ask(question) }
        }
    }

    private var canSend: Bool { !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !busy }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chiedi a Claude").font(.system(size: 22, weight: .bold)).tracking(-0.2)
            Text("Risponde usando trascrizione, nota e i tuoi appunti, con il minuto da cui prende ogni informazione.")
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
                Hairline()
            }
        }
    }

    private func ask(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        question = ""
        busy = true
        Task {
            let answer = await state.ask(q, about: meeting)
            history.append((q, answer))
            busy = false
        }
    }
}

/// Domanda + risposta, separate dalle altre da un filetto.
struct AnswerBlock: View {
    let question: String
    let answer: String
    var first = false
    var answerText: String? = nil      // testo già trasformato (es. citazioni cliccabili); altrimenti `answer`

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !first { Hairline().padding(.bottom, 6) }
            Text(question).font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
            MarkdownView(text: answerText ?? answer)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer, forType: .string)
            } label: { Label("Copia", systemImage: "doc.on.doc").font(.caption) }
                .buttonStyle(.borderless)
                .tint(Theme.brand)
        }
        .padding(.vertical, 12)
    }
}

/// Barra di input in fondo, con filetto sopra.
struct AskInputBar: View {
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let canSend: Bool
    let send: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...5)
                    .focused(focused)
                    .onSubmit(send)
                    .padding(.vertical, 6)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                        .foregroundStyle(canSend ? Theme.brandFill : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Invia (⌘↩)")
                .accessibilityLabel("Invia la domanda")
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
        }
        .background(Theme.canvas)
    }
}

// MARK: - Modifica

struct EditMeetingSheet: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss
    @ViewState private var setup: MeetingSetup

    init(state: AppState, meeting: Meeting) {
        self.state = state
        self.meeting = meeting
        var s = meeting.setup
        if s.title.trimmingCharacters(in: .whitespaces).isEmpty { s.title = meeting.title }   // mostra il titolo attuale
        _setup = ViewState(initialValue: s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Dettagli della riunione").font(.system(size: 20, weight: .bold))
            Form {
                if meeting.inVault {
                    Picker("Cliente", selection: Binding(
                        get: { setup.client },
                        set: { setup.client = $0; setup.clientSource = "manuale" })) {
                        Text("Nessuno (Inbox, da smistare)").tag(VaultClient?.none)
                        ForEach(state.clients) { c in Text("\(c.name) · \(c.group)").tag(VaultClient?.some(c)) }
                    }
                }
                TextField("Titolo", text: $setup.title)
                TextField("Partecipanti", text: $setup.participants)
                Picker("Tipo", selection: $setup.template) {
                    ForEach(NoteTemplate.allCases) { Text($0.label).tag($0) }
                }
            }
            .formStyle(.grouped)
            Text(setup.client != meeting.setup.client
                 ? "Nota, trascrizione e audio vengono spostati nelle cartelle del cliente scelto; hub, decisioni, daily e indice si aggiornano. Il riassunto resta quello che c'è."
                 : "Il riassunto resta quello che c'è: cambiano solo i dettagli (e il nome del file se cambi il titolo). Per riscriverlo usa \"Rigenera la nota\".")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Salva") {
                    var m = meeting
                    m.setup = setup
                    state.updateDetails(m)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brandFill)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 500)
        .onAppear { if state.clients.isEmpty { state.reloadVault() } }
    }
}

// MARK: - Player

@MainActor
final class PlayerModel: ObservableObject {
    let player: AVPlayer
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var rate: Float = 1
    nonisolated(unsafe) private var observer: Any?
    let available: Bool

    init(url: URL) {
        available = FileManager.default.fileExists(atPath: url.path)
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = t.seconds
                self.isPlaying = self.player.timeControlStatus == .playing
            }
        }
        Task { [weak self] in
            guard let item = self?.player.currentItem,
                  let d = try? await item.asset.load(.duration) else { return }
            self?.duration = d.seconds.isFinite ? d.seconds : 0
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
    }

    func toggle() {
        if player.timeControlStatus == .playing { player.pause(); isPlaying = false }
        else { player.playImmediately(atRate: rate); isPlaying = true }
    }

    func seek(to seconds: Double, play: Bool = false) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = seconds
        if play { player.playImmediately(atRate: rate); isPlaying = true }
    }

    func skip(_ delta: Double) { seek(to: time + delta, play: isPlaying) }

    func setRate(_ r: Float) {
        rate = r
        if player.timeControlStatus == .playing { player.rate = r }
    }
}

struct PlayerBar: View {
    @ObservedObject var player: PlayerModel

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 14) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.brandFill))
                        .contentShape(Circle())
                }
                .help(player.isPlaying ? "Pausa" : "Riproduci")
                .accessibilityLabel(player.isPlaying ? "Pausa" : "Riproduci")
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    .help("Indietro di 15 secondi").accessibilityLabel("Indietro di 15 secondi")
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                    .help("Avanti di 15 secondi").accessibilityLabel("Avanti di 15 secondi")
                Text(Merge.timestamp(player.time)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary).frame(width: 44)
                Slider(value: Binding(get: { player.time }, set: { player.seek(to: $0, play: player.isPlaying) }),
                       in: 0...max(player.duration, 1))
                    .tint(Theme.brandFill)
                    .controlSize(.small)
                    .accessibilityLabel("Posizione nell'audio")
                Text(Merge.timestamp(player.duration)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary).frame(width: 44)
                Menu {
                    ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { r in
                        Button("\(r, specifier: "%g")×") { player.setRate(Float(r)) }
                    }
                } label: {
                    Text("\(player.rate, specifier: "%g")×").font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Velocità di riproduzione")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
        }
        .background(.bar)
        .disabled(!player.available)
        .overlay {
            if !player.available {
                Label("Audio non più disponibile (eliminato o spostato)", systemImage: "speaker.slash")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.xs)
                    .background(Capsule().fill(Theme.surface))
            }
        }
    }
}

// MARK: - Markdown (titoli, elenchi, checklist, grassetto/corsivo/codice inline)

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, line in
                row(line, first: i == 0)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Righe non vuote (gli spazi tra i blocchi li gestisce il layout).
    private var blocks: [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @ViewBuilder
    private func row(_ line: String, first: Bool) -> some View {
        if line.hasPrefix("## ") {
            RuledLabel(text: String(line.dropFirst(3)), rule: !first)
                .padding(.top, first ? 0 : 14)
                .padding(.bottom, 2)
        } else if line.hasPrefix("# ") {
            VStack(alignment: .leading, spacing: 10) {
                if !first { Hairline() }
                Text(inline(String(line.dropFirst(2))))
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.2)
            }
            .padding(.top, first ? 0 : 14)
            .padding(.bottom, 2)
        } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: line.hasPrefix("- [x] ") ? "checkmark.square" : "square").foregroundStyle(.secondary)
                Text(inline(String(line.dropFirst(6)))).font(.system(size: 14)).lineSpacing(4)
            }
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("–").foregroundStyle(.tertiary)
                Text(inline(String(line.dropFirst(2)))).font(.system(size: 14)).lineSpacing(4)
            }
        } else {
            Text(inline(line)).font(.system(size: 14)).lineSpacing(4)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        // [[Nota|alias]] → alias, [[Nota]] → Nota
        var t = s
        while let open = t.range(of: "[["), let close = t[open.upperBound...].range(of: "]]") {
            let inner = t[open.upperBound..<close.lowerBound]
            let shown = inner.split(separator: "|").last.map(String.init) ?? String(inner)
            t.replaceSubrange(open.lowerBound..<close.upperBound, with: shown)
        }
        t = Timestamps.linkify(t)   // [12:34] → link che fa partire l'audio da quel minuto
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: t, options: options)) ?? AttributedString(t)
    }
}
