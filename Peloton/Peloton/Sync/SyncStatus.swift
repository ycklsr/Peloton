import Foundation

/// Everything the interface needs to know about the state of the sync.
///
/// A single principle: **a failure is always visible, never silent.**
/// But it is never dramatic any more — the local cache keeps the data, so an
/// unreachable folder delays the sync without losing anything.
nonisolated struct SyncStatus: Codable, Equatable, Sendable {

    /// Version number of the log, which only ever goes up.
    ///
    /// The HTML uses it to ignore a response that arrived late. Without it, a
    /// read of the folder that started BEFORE an action can come back AFTER
    /// it, and make that action vanish from the screen until the next
    /// sync.
    var revision = 0

    /// Has a shared folder been chosen?
    var hasFolder = false

    /// Last successful read of the folder (epoch milliseconds, for the JS).
    var lastPullAt: Double?

    /// Last successful publication of our facts into the folder.
    var lastPushAt: Double?

    /// `true` if our latest facts have not reached the folder yet.
    /// They are safe locally: this is a delay, not a loss.
    var awaitingPush = false

    /// Readable message explaining the last problem, `nil` if all is well.
    var problem: String?

    /// Name of this device, shown in the settings.
    var deviceName = DeviceIdentity.name

    /// Number of known facts — an order of magnitude useful for diagnosis.
    var eventCount = 0

    /// Who contributed to the log, and when they last did.
    var contributors: [Contributor] = []

    struct Contributor: Codable, Equatable {
        var name: String
        var isThisDevice: Bool
        var eventCount: Int
        /// ISO wall-clock date of this device's last fact (for display).
        var lastActivity: String?
    }
}
