import Foundation

/// Pulizia dell'audio vecchio: dopo N giorni (AUDIO_RETENTION_DAYS, 0 = mai) l'audio delle riunioni va nel Cestino.
/// Nota, trascrizione, statistiche e minuti restano: servono solo i segmenti già salvati in archivio.
enum AudioCleanup {
    struct Report {
        var trashed: [String] = []      // titoli delle riunioni
        var freedBytes: Int64 = 0
        var errors: [String] = []
    }

    static func run(config: Config, skip: Set<String> = []) -> Report {
        var report = Report()
        let days = config.int("AUDIO_RETENTION_DAYS", default: 0)
        guard days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return report }
        let fm = FileManager.default
        let vault = config.vaultRoot.map(Vault.init(root:))
        let today = Vault.dayFormatter.string(from: Date())
        var log: [String] = []

        for m in MeetingStore.all() where m.date < cutoff && !skip.contains(m.id) {
            let audio = m.audioURL
            // Solo l'audio della riunione (.m4a) e solo se c'è ancora.
            guard audio.pathExtension.lowercased() == "m4a", fm.fileExists(atPath: audio.path) else { continue }
            let size = (try? fm.attributesOfItem(atPath: audio.path)[.size] as? Int64) ?? 0
            do {
                try fm.trashItem(at: audio, resultingItemURL: nil)
            } catch {
                report.errors.append("\(m.title): \(error.localizedDescription)")
                continue
            }
            report.trashed.append(m.title)
            report.freedBytes += size

            // Nel vault: la nota di trascrizione non deve restare con un riquadro audio rotto.
            if let vault, let t = m.transcriptPath,
               t.hasPrefix(vault.root.standardizedFileURL.path + "/") || t.hasPrefix(vault.root.path + "/"),
               let text = try? String(contentsOfFile: t, encoding: .utf8) {
                let name = audio.lastPathComponent
                let updated = text
                    .replacingOccurrences(of: "![[\(name)]]", with: "_Audio eliminato il \(today) (pulizia automatica dopo \(days) giorni). La trascrizione qui sotto resta._")
                    .replacingOccurrences(of: "audio: \"[[\(name)]]\"", with: "audio: \"eliminato il \(today)\"")
                if updated != text { try? updated.write(toFile: t, atomically: true, encoding: .utf8) }
                log.append("cleanup | audio di \(m.noteURL.deletingPathExtension().lastPathComponent) nel Cestino (più vecchio di \(days) giorni)")
            }
            // Cartella audio/ rimasta vuota (vecchie note in Chiamate/audio o Inbox/audio): via anche lei.
            let dir = audio.deletingLastPathComponent()
            if dir.lastPathComponent == "audio",
               (try? fm.contentsOfDirectory(atPath: dir.path))?.filter({ !$0.hasPrefix(".") }).isEmpty == true {
                try? fm.removeItem(at: dir)
            }
        }
        if let vault, !log.isEmpty { try? vault.appendLog(date: Date(), entries: log) }
        return report
    }
}
