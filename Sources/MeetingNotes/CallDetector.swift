import AppKit
import CoreAudio
import Foundation

/// App di videochiamata note (per nome e per ordinare le liste).
enum CallApps {
    static let names: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.google.Chrome": "Google Chrome",
        "com.apple.Safari": "Safari",
        "company.thebrowser.Browser": "Arc",
        "company.thebrowser.dia": "Dia",
        "ai.perplexity.comet": "Comet",
        "com.operasoftware.Opera": "Opera",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.brave.Browser": "Brave",
        "com.microsoft.edgemac": "Microsoft Edge",
        "org.mozilla.firefox": "Firefox",
        "net.whatsapp.WhatsApp": "WhatsApp",
    ]

    /// Anche le web app installate dal browser (es. Google Meet come app di Chrome: com.google.Chrome.app.<id>)
    /// e qualunque browser installato (le call su Meet passano dal browser, qualunque esso sia).
    static func isCallApp(_ bundleID: String) -> Bool {
        names[bundleID] != nil || names.keys.contains { bundleID.hasPrefix($0 + ".app.") } || isBrowser(bundleID)
    }

    /// Tutte le app che aprono i link https (Chrome, Safari, Arc, Dia, Brave, Edge, Firefox…), lette dal sistema.
    nonisolated(unsafe) private static var browserCache: (Set<String>, Date)?
    static func isBrowser(_ bundleID: String) -> Bool {
        if let (set, at) = browserCache, Date().timeIntervalSince(at) < 600 { return set.contains(bundleID) }
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://meet.google.com")!)
        let set = Set(urls.compactMap { Bundle(url: $0)?.bundleIdentifier })
        browserCache = (set, Date())
        return set.contains(bundleID)
    }
}

/// Rileva l'inizio e la fine di una call guardando quali app usano il microfono
/// (oggetti processo di Core Audio, macOS 14.2+). Fa polling ogni 3 secondi: costa pochissimo.
@MainActor
final class CallDetector {
    struct Detection { let bundleID: String; let appName: String }

    var onCallStarted: ((Detection) -> Void)?
    var onCallEnded: ((Detection) -> Void)?

    private var timer: Timer?
    private var active: Detection?
    private var goneSince: Date?
    private let ownBundle = Bundle.main.bundleIdentifier ?? "com.edoardo.meetingnotes"

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        active = nil
    }

    private func poll() {
        let users = CallDetector.appsUsingMicrophone().filter { !$0.bundleID.hasPrefix(ownBundle) }
        if let current = active {
            if users.contains(where: { $0.bundleID == current.bundleID }) {
                goneSince = nil
            } else if let since = goneSince {
                // 12 s senza microfono: la call è finita. Il mute nella call non conta: l'app tiene comunque
                // aperto il microfono, lo rilascia solo quando esci.
                if Date().timeIntervalSince(since) > 12 {
                    active = nil
                    goneSince = nil
                    onCallEnded?(current)
                }
            } else {
                goneSince = Date()
            }
        } else if let first = users.first(where: { CallApps.isCallApp($0.bundleID) }) {
            // Solo app di videochiamata e browser: niente falsi allarmi da dettatura, Memo Vocali, ecc.
            active = first
            onCallStarted?(first)
        }
    }

    /// App (con interfaccia) che stanno registrando dal microfono in questo momento.
    static func appsUsingMicrophone() -> [Detection] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        let regularApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var out: [Detection] = []
        for id in ids {
            var running: UInt32 = 0
            var rsize = UInt32(MemoryLayout<UInt32>.size)
            var raddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &raddr, 0, nil, &rsize, &running) == noErr, running != 0 else { continue }

            var bundle: Unmanaged<CFString>?
            var bsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var baddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &baddr, 0, nil, &bsize, &bundle) == noErr,
                  let bid = bundle?.takeRetainedValue() as String?, !bid.isEmpty else { continue }

            // I browser registrano dal processo "helper": risaliamo all'app principale per prefisso.
            guard let app = regularApps.first(where: { bid == $0.bundleIdentifier || bid.hasPrefix(($0.bundleIdentifier ?? "\u{0}") + ".") }),
                  let appID = app.bundleIdentifier else { continue }
            if !out.contains(where: { $0.bundleID == appID }) {
                out.append(Detection(bundleID: appID, appName: CallApps.names[appID] ?? app.localizedName ?? appID))
            }
        }
        return out
    }
}
