import EventKit
import Foundation

/// Evento di calendario in corso (o che inizia a breve): titolo e partecipanti per precompilare la riunione.
/// Legge i calendari configurati in macOS (anche Google/Outlook se aggiunti in Impostazioni → Account Internet).
enum CalendarHelper {
    private static let store = EKEventStore()

    struct Current {
        let title: String
        let attendees: [String]
    }

    static func currentEvent() async -> Current? {
        guard (try? await store.requestFullAccessToEvents()) == true else { return nil }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-4 * 3600),
                                                 end: now.addingTimeInterval(15 * 60), calendars: nil)
        let candidates = store.events(matching: predicate).filter {
            !$0.isAllDay && $0.startDate <= now.addingTimeInterval(10 * 60) && $0.endDate >= now
        }
        guard let event = candidates.min(by: { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) })
        else { return nil }
        let attendees = (event.attendees ?? [])
            .filter { !$0.isCurrentUser }
            .compactMap { p -> String? in
                if let name = p.name, !name.contains("@") { return name }
                return p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            }
        return Current(title: event.title ?? "", attendees: attendees)
    }

    /// Cliente il cui nome compare nel titolo o tra i partecipanti dell'evento.
    static func guessClient(_ event: Current, in clients: [VaultClient]) -> VaultClient? {
        let haystack = ([event.title] + event.attendees).joined(separator: " ").lowercased()
        let squashed = haystack.replacingOccurrences(of: " ", with: "")
        return clients
            .sorted { $0.name.count > $1.name.count } // il nome più specifico vince
            .first { c in
                let n = c.name.lowercased()
                return haystack.contains(n) || squashed.contains(n.replacingOccurrences(of: " ", with: ""))
            }
    }
}
