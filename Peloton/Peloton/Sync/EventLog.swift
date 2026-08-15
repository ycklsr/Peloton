import Foundation

/// The log: a set of facts, without duplicates, in total order.
///
/// A log is always *normalized* — sorted and deduplicated the moment it is
/// built. There is therefore no such thing as a "not yet tidied" log that the
/// rest of the code would have to be wary of.
///
/// ## Why merging cannot go wrong
///
/// `merging` is a plain union of sets. It is therefore:
/// - **commutative** — merging A then B gives the same result as B then A;
/// - **associative** — the grouping order does not matter at all;
/// - **idempotent** — merging an already known log again changes nothing.
///
/// These three properties are precisely what the old "last save wins" sync
/// was missing: there is nothing left to arbitrate, and therefore nothing
/// left to lose.
nonisolated struct EventLog: Codable, Equatable, Sendable {

    /// File format version. A safeguard should the format ever evolve.
    static let currentFormat = 1

    private(set) var events: [SyncEvent]

    init(_ events: [SyncEvent] = []) {
        self.events = EventLog.normalized(events)
    }

    // MARK: Composition

    /// Brings several logs together into one.
    static func merging(_ logs: [EventLog]) -> EventLog {
        EventLog(logs.flatMap(\.events))
    }

    /// Returns a new log enriched with `newEvents`.
    func appending(_ newEvents: [SyncEvent]) -> EventLog {
        EventLog(events + newEvents)
    }

    /// What THIS device is allowed to write into the folder.
    ///
    /// Its own facts, of course — this filter is what guarantees that no
    /// file ever has two authors. Plus those carried over from the old save
    /// file: they belong to no device, and somebody has to carry them, or
    /// else they would only ever live in the local copies. Since their
    /// identity is computed from their content, two devices that both publish
    /// them write exactly the same facts: they deduplicate one another
    /// instead of piling up.
    func publishable(by device: String) -> EventLog {
        EventLog(events.filter { $0.device == device || $0.device == SyncEvent.legacyDevice })
    }

    // MARK: Clock

    /// The number to give the next fact born on this device.
    ///
    /// `max(seen) + 1`: a fact created now necessarily lands after everything
    /// this device knows about, including what came from the other device.
    var nextOrder: Int { (events.last?.order ?? 0) + 1 }

    /// Builds a dated and numbered fact, ready to be appended.
    ///
    /// `sequence` offsets the clock when several facts are born of a single
    /// gesture, so that they keep the order in which they were emitted.
    func makeEvent(kind: String, data: JSONValue, sequence: Int = 0) -> SyncEvent {
        SyncEvent(id: UUID().uuidString,
                  order: nextOrder + sequence,
                  device: DeviceIdentity.id,
                  time: EventLog.isoFormatter.string(from: Date()),
                  kind: kind,
                  data: data)
    }

    // MARK: Internals

    private static func normalized(_ events: [SyncEvent]) -> [SyncEvent] {
        var seen = Set<String>()
        var unique: [SyncEvent] = []
        unique.reserveCapacity(events.count)
        for event in events where seen.insert(event.id).inserted {
            unique.append(event)
        }
        return unique.sorted { $0.isOrderedBefore($1) }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// MARK: - File format

/// What one finds inside `peloton-<device>.json`.
///
/// The device's readable name is stored *in* the file rather than in its file
/// name: renaming your Mac therefore does not create a second orphan file.
nonisolated struct LogFile: Codable, Sendable {
    var format: Int = EventLog.currentFormat
    var deviceId: String
    var deviceName: String
    var events: [SyncEvent]

    init(log: EventLog, deviceId: String, deviceName: String) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.events = log.events
    }

    var log: EventLog { EventLog(events) }

    // MARK: Serialization

    /// Readable JSON: a save file must stay inspectable with the naked eye
    /// and comparable with `diff`. Sorted keys keep successive versions
    /// stable.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> LogFile {
        try JSONDecoder().decode(LogFile.self, from: data)
    }
}
