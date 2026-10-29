import AppKit
import UniformTypeIdentifiers
import UserNotifications

/// Icona e menu nella barra dei menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let state = AppState.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotchBridge.listen()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        state.onChange = { [weak self] in self?.refreshButton() }
        NSApp.mainMenu = makeMainMenu()
        Notifier.setup(delegate: self)
        HotKey.handler = { [weak self] in self?.hotKeyPressed() }
        state.applySettings()
        state.reloadMeetings()
        state.refreshNotificationStatus()
        refreshButton()

        // Per test e automazioni: --open archive|panel|settings
        if let i = CommandLine.arguments.firstIndex(of: "--open"), i + 1 < CommandLine.arguments.count {
            switch CommandLine.arguments[i + 1] {
            case "archive": WindowManager.shared.showArchive()
            case "askall": WindowManager.shared.showArchive(select: ArchiveView.askAllID)
            case "settings": WindowManager.shared.showSettings()
            case "panel": Task { await state.prepareDraft(); WindowManager.shared.showPanel() }
            case let arg where arg.hasPrefix("meeting:"): WindowManager.shared.showArchive(select: String(arg.dropFirst(8)))
            default: break
            }
        }
        // Per test: --test-record <secondi> <cartella> registra, ferma e chiude l'app (esito in <cartella>/result.txt).
        if let i = CommandLine.arguments.firstIndex(of: "--test-record"), i + 2 < CommandLine.arguments.count {
            let seconds = Double(CommandLine.arguments[i + 1]) ?? 5
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 2], isDirectory: true)
            Task {
                var log = ""
                let rec = Recorder()
                do {
                    try await rec.start(into: dir.appendingPathComponent("rec"), setup: MeetingSetup())
                    log += "started\n"
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    log += "levels mic=\(rec.micLevel) system=\(rec.systemLevel)\n"
                    _ = try await rec.stop(setup: MeetingSetup())
                    log += "stopped\n"
                } catch {
                    log += "error: \(error.localizedDescription)\n"
                }
                try? log.write(to: dir.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
        // Per test: --test-live <secondi> <file> registra, salva le righe della trascrizione dal vivo e chiude (nessuna nota).
        if let i = CommandLine.arguments.firstIndex(of: "--test-live"), i + 2 < CommandLine.arguments.count {
            let seconds = Double(CommandLine.arguments[i + 1]) ?? 10
            let out = URL(fileURLWithPath: CommandLine.arguments[i + 2])
            Task {
                await state.start()
                let folder = state.recorder.folder
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                var log = "status: \(state.liveStatus ?? "ok") error: \(state.lastError ?? "-") heardSystem: \(state.recorder.systemHeardSomething) folder: \(folder?.path ?? "-")\n"
                log += state.liveLines.map { "[\(Merge.timestamp($0.start))] \($0.speaker)\($0.isFinal ? "" : " (provv.)"): \($0.text)" }.joined(separator: "\n")
                try? log.write(to: out, atomically: true, encoding: .utf8)
                await state.stopForQuit()
                if !CommandLine.arguments.contains("--keep"), let folder { try? FileManager.default.removeItem(at: folder) }
                NSApp.terminate(nil)
            }
        }
        // --test-notify: invia una notifica di prova (per controllare icona e permessi).
        if CommandLine.arguments.contains("--test-notify") {
            Notifier.post(title: "Meeting Notes", body: "Notifica di prova: se vedi il logo nuovo è tutto a posto.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        }
                // Diagnostica: --diagnose <file> scrive lo stato di notifiche, rilevamento call e link, poi chiude.
        if let i = CommandLine.arguments.firstIndex(of: "--diagnose"), i + 1 < CommandLine.arguments.count {
            let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            Task {
                var lines: [String] = []
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                lines.append("notifiche: autorizzazione=\(settings.authorizationStatus.rawValue) (2 = consentite) alert=\(settings.alertSetting.rawValue)")
                lines.append("rileva call: \(state.config.bool("AUTO_DETECT_CALLS", default: true)) · link: \(state.config.bool("DETECT_MEETING_LINKS", default: true))")
                lines.append("app che usano il microfono: \(CallDetector.appsUsingMicrophone().map { "\($0.appName) [\($0.bundleID)] call=\(CallApps.isCallApp($0.bundleID))" })")
                for b in ["company.thebrowser.dia", "com.google.Chrome", "com.apple.Safari"] { lines.append("\(b) browser=\(CallApps.isBrowser(b))") }
                try? await Task.sleep(nanoseconds: 9_000_000_000)   // lascia girare il controllo dei link
                lines.append("ultimo controllo link: \(state.linkDetector.lastProbe)")
                if let (d, at) = state.linkDetector.lastDetection { lines.append("ultimo link: \(d.service) \(d.title ?? "-") \(at)") }
                try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
        // Per test: --snapshot <cartella> salva un PNG di ogni finestra aperta dopo 3 secondi.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                for (n, w) in NSApp.windows.enumerated() where w.isVisible {
                    guard let view = w.contentView?.superview ?? w.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let name = w.title.isEmpty ? "window-\(n)" : w.title
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
                }
            }
        }
    }

    // MARK: - Dock e menu dell'app

    /// Clic sull'icona nel Dock senza finestre aperte: apre l'archivio.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Durante l'avvio di una registrazione (es. clic su "Registra" nella notifica) l'archivio non si apre.
        let justStarted = Date().timeIntervalSince(state.lastQuickStart) < 5
        if !flag, !justStarted, state.phase == .idle { WindowManager.shared.showArchive() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Menu standard dell'app (serve anche per ⌘C / ⌘V / ⌘Z nei campi di testo).
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", target: AnyObject? = nil,
                  mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        submenu("Meeting Notes", [
            item("Informazioni su Meeting Notes", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Impostazioni…", #selector(openSettings), ",", target: self),
            .separator(),
            item("Nascondi Meeting Notes", #selector(NSApplication.hide(_:)), "h"),
            item("Nascondi altre", #selector(NSApplication.hideOtherApplications(_:)), "h", mods: [.command, .option]),
            item("Mostra tutte", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Esci da Meeting Notes", #selector(quit), "q", target: self),
        ])
        submenu("Archivio", [
            item("Nuova registrazione…", #selector(newRecording), "n", target: self),
            item("Avvia registrazione", #selector(quickStart), "r", target: self, mods: [.command, .option, .control]),
            .separator(),
            item("Importa un file audio…", #selector(importAudio), "i", target: self),
            item("Rielabora registrazioni in sospeso", #selector(processPending), target: self),
            .separator(),
            item("Chiudi finestra", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Modifica", [
            item("Annulla", Selector(("undo:")), "z"),
            item("Ripeti", Selector(("redo:")), "z", mods: [.command, .shift]),
            .separator(),
            item("Taglia", #selector(NSText.cut(_:)), "x"),
            item("Copia", #selector(NSText.copy(_:)), "c"),
            item("Incolla", #selector(NSText.paste(_:)), "v"),
            item("Seleziona tutto", #selector(NSText.selectAll(_:)), "a"),
        ])
        let windowMenu = NSMenu(title: "Finestra")
        windowMenu.addItem(item("Archivio riunioni", #selector(openArchive), "0", target: self))
        windowMenu.addItem(item("Pannello di registrazione", #selector(showPanel), "1", target: self))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Riduci a icona", #selector(NSWindow.performMiniaturize(_:)), "m"))
        let windowItem = NSMenuItem(title: "Finestra", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }

    // MARK: - Pulsante

    private func refreshButton() {
        guard let button = statusItem.button else { return }
        let t = Int(state.elapsed)
        let time = String(format: " %02d:%02d", t / 60, t % 60)
        switch state.phase {
        case .recording:
            button.image = MenuBarIcon.image(.wave)
            button.contentTintColor = state.isPaused ? .systemOrange : .systemRed
            button.title = time
        case .starting, .stopping:
            button.image = MenuBarIcon.image(.dots)
            button.contentTintColor = nil
            button.title = ""
        case .idle:
            button.image = MenuBarIcon.image(state.processing.isEmpty ? .wave : .dots)
            button.contentTintColor = nil
            button.title = ""
        }
        button.imagePosition = .imageLeading
    }

    // MARK: - Menu (ricostruito a ogni apertura)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        switch state.phase {
        case .recording:
            let t = Int(state.elapsed)
            status = String(format: "%@ %02d:%02d · %@", state.isPaused ? "In pausa" : "In registrazione", t / 60, t % 60,
                            state.draft.resolvedTitle(at: Date()))
        case .starting: status = "Avvio…"
        case .stopping: status = "Chiudo la registrazione…"
        case .idle:
            status = state.processing.isEmpty ? "Pronto"
                : "Elaboro: " + state.processing.sorted { $0.key < $1.key }.map(\.value).joined(separator: " · ")
        }
        let s = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        s.isEnabled = false
        menu.addItem(s)
        if state.notificationsDenied {
            let warn = add(menu, "Notifiche disattivate: attivale per le proposte di registrazione…", #selector(openNotificationSettings),
                           symbol: "bell.slash")
            warn.toolTip = "Senza notifiche non arrivano gli avvisi \"Stai entrando in una call: registro?\""
        }
        menu.addItem(.separator())
        state.refreshNotificationStatus()

        if state.phase == .recording {
            add(menu, "Mostra pannello", #selector(showPanel), symbol: "macwindow")
            add(menu, state.isPaused ? "Riprendi" : "Pausa", #selector(togglePause), key: "p",
                symbol: state.isPaused ? "play.fill" : "pause.fill")
            add(menu, "Segna momento", #selector(bookmark), key: "b", symbol: "star")
            add(menu, "Ferma registrazione", #selector(stop), key: "s", symbol: "stop.fill")
        } else if state.phase == .idle {
            let quick = add(menu, "Avvia registrazione", #selector(quickStart), key: "r", symbol: "record.circle")
            quick.keyEquivalentModifierMask = [.command, .option, .control]
            add(menu, "Nuova registrazione…", #selector(newRecording), key: "n", symbol: "square.and.pencil")
        }
        menu.addItem(.separator())
        add(menu, "Archivio riunioni…", #selector(openArchive), key: "a", symbol: "archivebox")
        if state.meetings.first != nil { add(menu, "Apri l'ultima nota", #selector(openLastNote), symbol: "doc.text") }
        add(menu, "Importa un file audio…", #selector(importAudio), symbol: "square.and.arrow.down")
        add(menu, "Rielabora registrazioni in sospeso", #selector(processPending), symbol: "arrow.clockwise")
        menu.addItem(.separator())
        add(menu, "Impostazioni…", #selector(openSettings), key: ",", symbol: "gearshape")
        add(menu, "Esci", #selector(quit), key: "q", symbol: "power")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(item)
        return item
    }

    // MARK: - Azioni

    @objc private func quickStart() { Task { await state.quickStart() } }
    @objc private func newRecording() {
        Task {
            await state.prepareDraft()
            WindowManager.shared.showPanel()
        }
    }
    @objc private func showPanel() { WindowManager.shared.showPanel() }
    @objc private func togglePause() { state.togglePause() }
    @objc private func bookmark() { state.bookmark() }
    @objc private func stop() { state.stop() }
    @objc private func openArchive() { WindowManager.shared.showArchive() }
    @objc private func openSettings() { WindowManager.shared.showSettings() }
    @objc private func processPending() { state.processPending() }
    @objc private func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!)
    }

    @objc private func openLastNote() {
        if let m = state.meetings.first { NoteOpener.open(m) }
    }

    @objc private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { panel.urls.forEach(state.importAudio) }
    }

    private func hotKeyPressed() {
        switch state.phase {
        case .idle: quickStart()
        case .recording: state.stop()
        default: break
        }
    }

    @objc private func quit() {
        if state.phase == .recording || !state.processing.isEmpty {
            let alert = NSAlert()
            alert.messageText = state.phase == .recording ? "Registrazione in corso" : "Elaborazione in corso"
            alert.informativeText = "Se esci ora, le tracce restano in ~/MeetingNotes/.recordings e puoi rielaborarle più tardi da \"Rielabora registrazioni in sospeso\"."
            alert.addButton(withTitle: "Esci comunque")
            alert.addButton(withTitle: "Annulla")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if state.phase == .recording {
                Task {
                    await state.stopForQuit()
                    NSApp.terminate(nil)
                }
                return
            }
        }
        NSApp.terminate(nil)
    }

    // MARK: - Notifiche

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        let meetingID = response.notification.request.content.userInfo["meeting"] as? String
        let title = response.notification.request.content.userInfo["title"] as? String
        Task { @MainActor in
            let state = AppState.shared
            if category == Notifier.startCategory, action == "RECORD" || action == UNNotificationDefaultActionIdentifier {
                await state.quickStart(title: title)
            } else if category == Notifier.stopCategory {
                if action == "STOP" { state.stop() } else { WindowManager.shared.showPanel(activate: false) }
            } else if let meetingID {
                WindowManager.shared.showArchive(select: meetingID)
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// Apre una nota in Obsidian (se è nel vault) o con l'app predefinita.
enum NoteOpener {
    @MainActor static func open(_ m: Meeting) {
        if m.inVault, let url = Vault.obsidianURL(for: m.noteURL),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(m.noteURL)
        }
    }
}
