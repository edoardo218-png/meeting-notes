import AppKit
import SwiftUI

/// Gestisce pannello di registrazione, archivio e impostazioni.
/// Mentre archivio o impostazioni sono aperti l'app compare nel Dock e in ⌘-Tab.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var panel: NSPanel?
    private var archive: NSWindow?
    private var settings: NSWindow?
    let archiveSelection = ArchiveSelection()

    /// `activate: false` (avvio rapido, notifica): il pannello compare sopra le altre finestre
    /// senza togliere il focus alla call.
    func showPanel(activate: Bool = true) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
                            backing: .buffered, defer: false)
            p.title = "Meeting Notes"
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // Escluso dalla condivisione schermo: i tuoi appunti non finiscono nella call.
            p.sharingType = .none
            p.contentView = NSHostingView(rootView: RecordingPanelView(state: AppState.shared))
            p.setFrameAutosaveName("RecordingPanel")
            if !p.setFrameUsingName("RecordingPanel"), let screen = NSScreen.main {
                let f = screen.visibleFrame
                p.setFrameOrigin(NSPoint(x: f.maxX - 400, y: f.maxY - 620))
            }
            panel = p
        }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
        } else {
            panel?.orderFrontRegardless()
        }
    }

    func closePanel() { panel?.orderOut(nil) }

    func showArchive(select id: String? = nil) {
        AppState.shared.reloadMeetings()
        if let id { archiveSelection.id = id }
        if archive == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Archivio riunioni"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: ArchiveView(state: AppState.shared, selection: archiveSelection))
            w.setFrameAutosaveName("Archive")
            if !w.setFrameUsingName("Archive") { w.center() }
            archive = w
        }
        show(archive)
    }

    func showSettings() {
        if settings == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Impostazioni"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsView(state: AppState.shared))
            w.center()
            settings = w
        }
        show(settings)
    }

    /// L'app resta nel Dock (impostazione "Mostra nel Dock", attiva di default); altrimenti ci entra solo
    /// mentre archivio o impostazioni sono aperti.
    static var showInDock: Bool { AppState.shared.config.bool("SHOW_IN_DOCK", default: true) }

    func applyDockPolicy() {
        let anyOpen = [archive, settings].compactMap { $0 }.contains { $0.isVisible }
        NSApp.setActivationPolicy(WindowManager.showInDock || anyOpen ? .regular : .accessory)
    }

    private func show(_ w: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let others = [archive, settings].compactMap { $0 }.filter { $0 !== closing && $0.isVisible }
        if others.isEmpty && !WindowManager.showInDock { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Riunione selezionata nell'archivio (impostabile da fuori, es. dal clic su una notifica).
final class ArchiveSelection: ObservableObject {
    @Published var id: String?
    /// Minuto da far partire quando si apre la riunione (clic su una citazione in "Chiedi a tutte le riunioni").
    var pendingSeek: Double?
}
