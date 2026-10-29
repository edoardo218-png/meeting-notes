import Foundation

/// Stato della registrazione per Soglia (l'app del notch, ~/Projects/soglia): una notifica distribuita a ogni cambio
/// di fase o di pausa, e su richiesta quando Soglia si avvia. Soglia mostra il pallino REC e la durata nel notch.
@MainActor
enum NotchBridge {
    static let stateName = Notification.Name("com.edoardo.meetingnotes.state")
    static let queryName = Notification.Name("com.edoardo.meetingnotes.query")

    static func post(_ state: AppState) {
        let phase: String
        switch state.phase {
        case .idle: phase = "idle"
        case .starting: phase = "starting"
        case .recording: phase = "recording"
        case .stopping: phase = "stopping"
        }
        DistributedNotificationCenter.default().postNotificationName(
            stateName, object: nil,
            userInfo: ["phase": phase, "isPaused": state.isPaused, "elapsed": state.recorder.elapsed],
            deliverImmediately: true)
    }

    static func listen() {
        DistributedNotificationCenter.default().addObserver(forName: queryName, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { post(AppState.shared) }
        }
    }
}
