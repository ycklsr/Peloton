import Foundation

/// A FACT: "this happened".
///
/// It is the only thing devices exchange with each other. A fact is
/// **immutable**: once born, it is never modified nor rewritten. Correcting
/// something means adding a new fact, never touching up an old one.
///
/// All the robustness of the sync flows from that immutability: merging two
/// devices means taking the union of two sets of facts. A union loses nothing,
/// does not depend on the order of arrival, and yields the same result whether
/// you do it once or ten times.
nonisolated struct SyncEvent: Codable, Equatable, Sendable {

    /// Unique identifier of the fact — the deduplication key.
    ///
    /// If the same fact turns up twice (re-reading the folder, restoring a
    /// backup, importing the old file over and over), it is recognized and
    /// ignored. That is what makes the whole operation replayable unharmed.
    let id: String

    /// A **logical** clock (Lamport counter), not a time of day.
    ///
    /// Each device numbers its facts with `max(everything it has seen) + 1`.
    /// Two devices whose wall clocks are ten minutes apart still produce a
    /// coherent order — which is precisely why the date is not what we sort
    /// on.
    let order: Int

    /// Authoring device. Used to break the tie between two facts of equal
    /// `order` (born without having seen each other) — and nothing else.
    let device: String

    /// Conventional author of facts taken from the old `peloton-sync.json`.
    /// They belong to no device: see `EventLog.publishable(by:)`.
    static let legacyDevice = "legacy"

    /// ISO 8601 wall-clock date. **Display only.**
    /// No decision relies on it: see `order`.
    let time: String

    /// Nature of the fact ("sessionLogged", "chapterStatusSet"…).
    /// Opaque to Swift: the meaning of these words is defined in the HTML.
    let kind: String

    /// Content of the fact. Opaque to Swift as well.
    let data: JSONValue

    /// Total order, identical on every device.
    ///
    /// The three successive criteria guarantee that there is never a perfect
    /// tie, hence never any ambiguity: two devices sorting the same set of
    /// facts obtain exactly the same sequence. That is what lets the HTML
    /// recompute an identical state everywhere.
    func isOrderedBefore(_ other: SyncEvent) -> Bool {
        if order != other.order { return order < other.order }
        if device != other.device { return device < other.device }
        return id < other.id
    }
}
