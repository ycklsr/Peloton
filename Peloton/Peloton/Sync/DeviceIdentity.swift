import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Stable identity of THIS device.
///
/// This is the cornerstone the whole sync architecture rests on:
/// **a device only ever writes its own file**, and this identifier is
/// that file's name. Two devices can therefore never write to the same
/// place — iCloud never has anything to arbitrate, and "conflict copies"
/// (`peloton-sync 2.json`) become impossible by construction.
///
/// The identifier is also what breaks the tie between two facts born at the
/// same logical instant: see `SyncEvent.isOrderedBefore`.
nonisolated enum DeviceIdentity {

    private static let storageKey = "peloton.device.id"

    /// UUID drawn once, then stable for the lifetime of the installation.
    ///
    /// If the app is uninstalled then reinstalled, a new identifier is born and
    /// the old file in the folder becomes an orphan: it is still **read**
    /// (so no data is lost), it is simply no longer written to.
    static let id: String = {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: storageKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: storageKey)
        return fresh
    }()

    /// Human-readable name ("Yannick's MacBook").
    ///
    /// Purely cosmetic — shown in the app to trace who did what.
    /// It NEVER takes part in a decision: two devices may carry the
    /// same name without anything breaking.
    ///
    /// It is captured once at launch by `refreshName()` then read back here,
    /// because the system APIs that provide it can only be queried from the
    /// main thread — whereas this name is written into the files, hence from a
    /// background thread.
    static var name: String {
        UserDefaults.standard.string(forKey: nameKey) ?? defaultName
    }

    /// Call at app startup. Keeps up with device renames.
    @MainActor
    static func refreshName() {
        #if os(macOS)
        let current = Host.current().localizedName ?? defaultName
        #else
        let current = UIDevice.current.name
        #endif
        UserDefaults.standard.set(current, forKey: nameKey)
    }

    private static let nameKey = "peloton.device.name"

    private static var defaultName: String {
        #if os(macOS)
        return "Mac"
        #else
        return "iPhone"
        #endif
    }

    /// Short, filename-safe fragment: `peloton-a1b2c3d4.json`.
    static var fileToken: String {
        String(id.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}
