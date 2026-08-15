import Foundation

/// The device's memory: a complete copy of the log, kept outside the iCloud
/// folder.
///
/// This is the safety net of the whole app. The old version had no local
/// persistence at all: if iCloud had not downloaded the file yet (plane, weak
/// network, "ghost" `.icloud` placeholder), the app had literally nothing to
/// show and got stuck on a waiting screen.
///
/// Here, **iCloud is a means of transport, not the memory**. The app starts
/// instantly from this copy, works entirely offline, and a failed write to the
/// folder never loses an action: it is already here, and will set off again at
/// the next contact.
nonisolated struct LocalStore: Sendable {

    private let fileURL: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Peloton", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("journal.json")
    }

    /// The log this device knows about. Empty log if the file does not exist
    /// yet (first launch) or if it is unreadable.
    func load() -> EventLog {
        guard let data = try? Data(contentsOf: fileURL) else { return EventLog() }
        do {
            return try LogFile.decoded(from: data).log
        } catch {
            // A corrupted cache must not stop the app from opening: we start
            // over from the iCloud folder, which holds the same facts.
            NSLog("Peloton — local cache unreadable, falling back to the folder: \(error)")
            return EventLog()
        }
    }

    /// Atomic write: the file is replaced in one go, never left half written
    /// even if the app is killed during the operation.
    func save(_ log: EventLog) {
        let file = LogFile(log: log,
                           deviceId: DeviceIdentity.id,
                           deviceName: DeviceIdentity.name)
        do {
            try file.encoded().write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Peloton — local cache write failed: \(error)")
        }
    }

    /// Wipes this device's memory (full reset).
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
