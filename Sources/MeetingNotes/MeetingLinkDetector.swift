import AppKit
import Foundation

/// Riconosce quando nel browser in primo piano è aperto il link di una call (Meet, Zoom web, Teams…),
/// già nella sala d'attesa, senza bisogno del calendario. Legge l'indirizzo e il titolo della scheda attiva
/// via AppleScript: macOS chiede una volta il permesso "controllare <browser>".
@MainActor
final class MeetingLinkDetector {
    struct Detection {
        let service: String
        let title: String?      // titolo della call dalla scheda (se non è solo un codice)
        let url: String
        let browserBundleID: String
    }

    var onMeetingOpened: ((Detection) -> Void)?
    private(set) var lastDetection: (Detection, Date)?

    private var timer: Timer?
    private var notified: [String: Date] = [:]     // link della call → quando abbiamo avvisato
    private var deniedBrowsers = Set<String>()
    private var unsupportedBrowsers = Set<String>()
    /// Ultimo esito, per la diagnostica.
    private(set) var lastProbe = "nessun controllo ancora"

    private static let browsers: [String: Script] = [
        "com.google.Chrome": .chromium, "com.google.Chrome.beta": .chromium, "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium, "company.thebrowser.Browser": .chromium, "com.vivaldi.Vivaldi": .chromium,
        "com.apple.Safari": .safari,
    ]

    enum Script { case chromium, safari }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let app = NSWorkspace.shared.frontmostApplication, let bid = app.bundleIdentifier,
              !deniedBrowsers.contains(bid), !unsupportedBrowsers.contains(bid) else { return }
        // Browser noti con la loro sintassi; ogni altro browser installato si prova con quella di Chrome
        // (la usano quasi tutti: Arc, Dia, Brave, Edge, Opera, Vivaldi…).
        guard let kind = MeetingLinkDetector.browsers[bid] ?? (CallApps.isBrowser(bid) ? .chromium : nil) else { return }
        guard let (url, title) = activeTab(bundleID: bid, kind: kind),
              let service = MeetingLinkDetector.service(for: url) else { return }
        let key = MeetingLinkDetector.normalize(url)
        if let last = notified[key], Date().timeIntervalSince(last) < 2 * 3600 { return }
        notified[key] = Date()
        let d = Detection(service: service, title: MeetingLinkDetector.cleanTitle(title, service: service), url: url, browserBundleID: bid)
        lastDetection = (d, Date())
        onMeetingOpened?(d)
    }

    private func activeTab(bundleID: String, kind: Script) -> (String, String)? {
        let source: String
        switch kind {
        case .chromium:
            source = "tell application id \"\(bundleID)\" to if (count of windows) > 0 then return {URL, title} of active tab of front window"
        case .safari:
            source = "tell application id \"\(bundleID)\" to if (count of windows) > 0 then return {URL, name} of current tab of front window"
        }
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            let code = error?[NSAppleScript.errorNumber] as? Int ?? 0
            lastProbe = "\(bundleID): errore AppleScript \(code) \(error?[NSAppleScript.errorMessage] as? String ?? "")"
            // -1743: permesso negato dall'utente. -1708/-1728/-2741: il browser non ha questa sintassi. Non riproviamo.
            if code == -1743 { deniedBrowsers.insert(bundleID) }
            else if [-1708, -1728, -2741, -2753].contains(code) { unsupportedBrowsers.insert(bundleID) }
            return nil
        }
        lastProbe = "\(bundleID): ok"
        guard result.numberOfItems >= 2,
              let url = result.atIndex(1)?.stringValue, let title = result.atIndex(2)?.stringValue else { return nil }
        return (url, title)
    }

    // MARK: - Riconoscimento dei link

    nonisolated static func service(for url: String) -> String? {
        let u = url.lowercased()
        let patterns: [(String, String)] = [
            (#"meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"#, "Google Meet"),
            (#"meet\.google\.com/lookup/"#, "Google Meet"),
            (#"zoom\.us/(j|wc|my)/"#, "Zoom"),
            (#"teams\.microsoft\.com/.*(meetup-join|meetingjoin|/meet/)"#, "Microsoft Teams"),
            (#"teams\.live\.com/meet/"#, "Microsoft Teams"),
            (#"whereby\.com/[^/?#]+"#, "Whereby"),
            (#"meet\.jit\.si/[^/?#]+"#, "Jitsi"),
            (#"app\.slack\.com/huddle/"#, "Slack Huddle"),
        ]
        return patterns.first { u.range(of: $0.0, options: .regularExpression) != nil }?.1
    }

    nonisolated static func normalize(_ url: String) -> String {
        var u = url.lowercased()
        if let q = u.firstIndex(where: { $0 == "?" || $0 == "#" }) { u = String(u[..<q]) }
        return u
    }

    /// "Meet - Call settimanale" → "Call settimanale"; i titoli che sono solo un codice o generici → nil.
    nonisolated static func cleanTitle(_ raw: String, service: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["Meet - ", "Meet – ", "Meet: "] where t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        for suffix in [" - Google Meet", " | Microsoft Teams", " - Zoom", " | Whereby", " - Jitsi Meet"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        t = t.trimmingCharacters(in: .whitespaces)
        let generic = ["meet", "google meet", "zoom", "zoom meeting", "riunione zoom", "microsoft teams", "teams", "whereby", "jitsi meet", ""]
        if generic.contains(t.lowercased()) { return nil }
        if t.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil { return nil }
        return t
    }
}
