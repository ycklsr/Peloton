import Foundation

/// The settings that only make sense on THIS device, and must therefore never
/// travel.
///
/// Two examples, both taken from the old version where they were wrongly
/// synchronized:
///
/// - **the running stopwatch** — a timer started on the Mac has no reason to
///   keep running on the iPhone. That very confusion is what forced the old
///   code to refuse any update "while a timer is running", at the cost of a
///   device that could silently stay out of date;
/// - **the last-opened date** — it serves to tell "here is what happened
///   while you were away". That absence belongs to the device being
///   reopened.
///
/// Keeping them here, outside the log, removes dozens of pointless writes to
/// iCloud and one special case in the synchronization.
nonisolated struct LocalPreferences: Sendable {

    private let storageKey = "peloton.local.preferences"

    func all() -> [String: JSONValue] {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else { return [:] }
        return decoded
    }

    func set(_ key: String, to value: JSONValue) {
        var values = all()
        if case .null = value { values.removeValue(forKey: key) } else { values[key] = value }
        guard let data = try? JSONEncoder().encode(values),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        UserDefaults.standard.set(raw, forKey: storageKey)
    }
}
