import SwiftUI

/// Pannello flottante: impostazione della riunione, controlli di registrazione, livelli e appunti.
struct RecordingPanelView: View {
    @ObservedObject var state: AppState
    @FocusState private var notesFocused: Bool
    @FocusState private var titleFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var pulse = false

    private var recording: Bool { state.phase == .recording }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let error = state.lastError { Banner(kind: .error, text: error) }
            if recording, let hint = state.systemAudioHint { Banner(kind: .warning, text: hint) }
            detailsSection
            if recording {
                metersSection
                if state.config.bool("LIVE_TRANSCRIPT", default: true) { liveSection }
            } else {
                audioSection
            }
            notesSection
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, 34)
        .padding(.bottom, Theme.Space.l)
        .frame(minWidth: 380, minHeight: 600)
        .background(Theme.canvas)
        .task {
            if state.clients.isEmpty { state.reloadVault() }
            await state.refreshDevices()
        }
        .onChange(of: state.draft) { state.draftChanged() }
        .onAppear {
            pulse = true
            // All'apertura il focus va sul titolo (in registrazione sugli appunti), non sul pulsante Registra.
            if recording { notesFocused = true } else { titleFocused = true }
        }
    }

    // MARK: Intestazione e controlli

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            if recording {
                Circle()
                    .fill(state.isPaused ? Theme.warning : Theme.record)
                    .frame(width: 10, height: 10)
                    .opacity(state.isPaused || reduceMotion ? 1 : (pulse ? 1 : 0.35))
                    .animation(reduceMotion || state.isPaused ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(timeString(state.elapsed))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(state.isPaused ? "In pausa" : "Registrazione in corso")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                Button { state.togglePause() } label: {
                    Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.track))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(state.isPaused ? "Riprendi" : "Pausa")
                .accessibilityLabel(state.isPaused ? "Riprendi" : "Pausa")
                Button { state.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 14).frame(height: 34)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(Theme.recordFill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: .command)
                .help("Ferma e crea la nota (⌘.)")
            } else {
                BrandMark(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.phase == .stopping ? "Chiudo la registrazione…" : "Nuova registrazione")
                        .font(.system(size: 15, weight: .semibold))
                    Text("⌃⌥⌘R da qualunque app").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await state.start() }
                } label: {
                    HStack(spacing: 6) {
                        if state.phase == .starting { ProgressView().controlSize(.small) }
                        else { Circle().fill(.white).frame(width: 9, height: 9) }
                        Text("Registra").font(.body.weight(.semibold))
                    }
                    .padding(.horizontal, 14).frame(height: 34)
                    .foregroundStyle(.white)
                    .background(Capsule().fill(Theme.recordFill))
                    .opacity(state.phase == .idle ? 1 : 0.6)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(state.phase != .idle)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Avvia la registrazione (⌘↩)")
            }
        }
    }

    // MARK: Dati della riunione

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Titolo della riunione", text: $state.draft.title)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .bold))
                .focused($titleFocused)
                .padding(.bottom, 10)
                .accessibilityLabel("Titolo della riunione")
            Hairline()
            if state.config.saveToVault { fieldRow("building.2") {
                Menu {
                    choice("Riconosci dalla call", selected: state.draft.client == nil) { setClient(nil) }
                    ForEach(groups, id: \.self) { group in
                        Section(group) {
                            ForEach(state.clients.filter { $0.group == group }) { c in
                                choice(c.name, selected: state.draft.client == c) { setClient(c) }
                            }
                        }
                    }
                } label: { menuLabel(state.draft.client?.name ?? "Riconosci dalla call") }
                .fieldMenu()
                .accessibilityLabel("Cliente")
            } }
            fieldRow("list.bullet.rectangle") {
                Menu {
                    ForEach(NoteTemplate.allCases) { t in
                        choice(t.label, selected: state.draft.template == t) { state.draft.template = t }
                    }
                } label: { menuLabel(state.draft.template.label) }
                .fieldMenu()
                .accessibilityLabel("Tipo di riunione")
            }
            fieldRow("person.2", divider: false) {
                TextField("Partecipanti, separati da virgola", text: $state.draft.participants)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Partecipanti")
            }
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { name in
                            Button { addParticipant(name) } label: {
                                Pill(text: name, symbol: "plus", tint: Theme.brand, fill: Theme.brandSoft)
                            }
                            .buttonStyle(.plain)
                            .help("Aggiungi \(name) ai partecipanti")
                        }
                    }
                    .padding(.leading, 28)
                    .padding(.bottom, 4)
                }
            }
            if let event = state.draft.calendarEvent {
                Label("Dal calendario: \(event)", systemImage: "calendar")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
            Hairline()
        }
    }

    /// Riga del modulo: icona a sinistra, controllo, filetto sotto.
    private func fieldRow<C: View>(_ symbol: String, divider: Bool = true, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
                content().frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7)
            if divider { Hairline().opacity(0.6).padding(.leading, 28) }
        }
    }

    /// Voce di menu con la spunta su quella scelta.
    @ViewBuilder private func choice(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    /// Valore scelto come testo, con le frecce piccole del menu: niente riquadri.
    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func setClient(_ c: VaultClient?) {
        state.draft.client = c
        state.draft.clientSource = c == nil ? nil : "manuale"
    }

    /// Intestazione di sezione: maiuscoletto, eventuale azione a destra.
    private func sectionHead<T: View>(_ title: String, @ViewBuilder trailing: () -> T = { EmptyView() }) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
    }

    private var groups: [String] { Array(Set(state.clients.map(\.group))).sorted() }

    private var suggestions: [String] {
        let current = Set(state.draft.participantList)
        return state.people.filter { !current.contains($0) }.prefix(6).map { $0 }
    }

    private func addParticipant(_ name: String) {
        var list = state.draft.participantList
        list.append(name)
        state.draft.participants = list.joined(separator: ", ")
    }

    // MARK: Audio

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHead("Audio").padding(.bottom, 4)
            fieldRow("mic") {
                Menu {
                    choice("Microfono di sistema", selected: state.draft.micDeviceID == nil) { state.draft.micDeviceID = nil }
                    ForEach(state.microphones) { mic in
                        choice(mic.name, selected: state.draft.micDeviceID == mic.id) { state.draft.micDeviceID = mic.id }
                    }
                } label: {
                    menuLabel(state.microphones.first { $0.id == state.draft.micDeviceID }?.name ?? "Microfono di sistema")
                }
                .fieldMenu()
                .accessibilityLabel("Microfono")
            }
            fieldRow("speaker.wave.2", divider: false) {
                Menu {
                    choice("Tutto l'audio del Mac", selected: state.draft.audioAppBundleID == nil) { state.draft.audioAppBundleID = nil }
                    ForEach(state.audioApps) { app in
                        choice("Solo \(app.name)", selected: state.draft.audioAppBundleID == app.id) { state.draft.audioAppBundleID = app.id }
                    }
                } label: {
                    menuLabel(state.audioApps.first { $0.id == state.draft.audioAppBundleID }.map { "Solo \($0.name)" } ?? "Tutto l'audio del Mac")
                }
                .fieldMenu()
                .accessibilityLabel("Audio della call")
            }
            Text("Con \"Solo un'app\" notifiche, musica e altri suoni del Mac restano fuori dalla registrazione.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 28)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var metersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHead("Livelli")
            LevelMeter(label: "Tu", level: state.micLevel, color: Theme.me)
            LevelMeter(label: "Altri", level: state.systemLevel, color: Theme.others)
        }
    }

    // MARK: Trascrizione dal vivo

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Hairline()
            sectionHead("Dal vivo") {
                Text("Clic su una frase per segnarla").font(.caption2).foregroundStyle(.tertiary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        if let status = state.liveStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        } else if state.liveLines.isEmpty {
                            Text("Il testo comparirà qui mentre parlate.").font(.caption).foregroundStyle(.tertiary)
                        }
                        ForEach(state.liveLines) { line in
                            Button { state.bookmark(line) } label: { liveRow(line) }
                                .buttonStyle(.plain)
                                .help("Aggiungi questa frase agli appunti")
                                .id(line.id)
                        }
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.liveLines.last?.text) {
                    guard let last = state.liveLines.last?.id else { return }
                    if reduceMotion { proxy.scrollTo(last, anchor: .bottom) }
                    else { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
            .frame(height: 150)
        }
    }

    private func liveRow(_ line: LiveLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(line.speaker)
                .font(.caption.weight(.semibold))
                .foregroundStyle(line.isMe ? Theme.me : Theme.others)
                .frame(width: 40, alignment: .leading)
            Text(line.text)
                .font(.callout)
                .italic(!line.isFinal)
                .foregroundStyle(line.isFinal ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: Appunti

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Hairline()
            sectionHead("Appunti") {
                if recording {
                    Button { state.bookmark(); notesFocused = true } label: {
                        Label("Segna momento", systemImage: "star")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .tint(Theme.brand)
                    .keyboardShortcut("b", modifiers: .command)
                    .help("Inserisce il minuto attuale negli appunti (⌘B)")
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $state.notes)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .focused($notesFocused)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, -5)
                    .accessibilityLabel("Appunti")
                if state.notes.isEmpty {
                    Text("Scrivi i punti importanti mentre parli: Claude li userà come guida per la nota.")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: recording ? 120 : 170)
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

private extension View {
    func fieldMenu() -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }
}
