import Carbon
import Foundation

/// Scorciatoia globale ⌃⌥⌘R (funziona anche quando l'app non è in primo piano, senza permessi extra).
enum HotKey {
    nonisolated(unsafe) static var handler: (() -> Void)?
    nonisolated(unsafe) private static var ref: EventHotKeyRef?
    nonisolated(unsafe) private static var installed = false

    static func register() {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.handler?() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        guard ref == nil else { return }
        let id = EventHotKeyID(signature: OSType(0x4D4E_4F54), id: 1) // "MNOT"
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | optionKey | controlKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }

    static func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
