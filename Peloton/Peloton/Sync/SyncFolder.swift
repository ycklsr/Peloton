import Foundation

/// The shared folder (typically `iCloud Drive/CRPE-Sync`).
///
/// ## The rule that holds everything together
///
/// **This device writes exactly one file: its own.** It reads the ones
/// belonging to the others, never modifies them, never deletes them. Since two
/// devices never write to the same place, iCloud has no conflict to resolve
/// and therefore never produces a "conflict copy". All the code that, in the
/// old version, read and then *deleted* those copies — at the risk of losing
/// data for good if the app crashed between the two steps —
/// no longer exists.
///
/// ## What the folder holds
///
/// - `peloton-<device>.json`           : one device's log (one per device)
/// - `peloton-backup-<device>-<date>.json` : safety net, 2 rolling days
/// - `peloton-sync.json`               : the old format, read once then ignored
nonisolated struct SyncFolder: Sendable {

    enum Failure: LocalizedError {
        case notConfigured
        case unreachable

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Aucun dossier de synchronisation n'a été choisi."
            case .unreachable:   return "Le dossier de synchronisation est inaccessible."
            }
        }
    }

    /// What a read of the folder reports back.
    struct Contents: Sendable {
        /// One file read per device (ours included). We keep the whole file
        /// rather than the log alone, so we know the readable name of every
        /// contributing device.
        var files: [LogFile] = []
        /// The old `peloton-sync.json`, raw, if it is still there.
        /// Converting it into facts is the HTML's job — see `LEGACY` in the
        /// `duel-crpe-2027.html` file.
        var legacy: String?
        /// At least one file could not be read (not downloaded by iCloud yet,
        /// for instance). The app reports it without losing anything.
        var hadUnreadableFile = false
    }

    private let bookmarkKey = "peloton.sync.folderBookmark"
    private let backupDayKey = "peloton.sync.lastBackupDay"
    /// Two dated copies per device — roughly 48 hours of cover.
    ///
    /// It used to be seven. The number is a window on a human slip, not on a
    /// synchronisation failure: sync loses nothing by construction, whereas
    /// "I deleted everything" needs to be noticed before the good copy is
    /// pruned. Two days is the window this app is given to notice.
    private let backupsKept = 2

    /// File name for THIS device. It is built on the identifier, not on the
    /// readable name: renaming your Mac therefore does not change file.
    private var myFileName: String { "peloton-\(DeviceIdentity.fileToken).json" }

    var isConfigured: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    // MARK: - Picking the folder

    /// Remembers the folder the user picked, as a "bookmark" that survives a
    /// restart and reopens access despite the sandbox.
    func remember(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        #if os(macOS)
        let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        #else
        let bookmark = try? url.bookmarkData()
        #endif

        // A failure must NEVER erase a valid bookmark already in place.
        guard let bookmark else {
            NSLog("Peloton — bookmark refused for \(url.path)")
            return
        }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    // MARK: - Reading

    /// Reads every log present in the folder.
    ///
    /// An unreadable file does not stop the others from being read: we report
    /// what we could read and raise the `hadUnreadableFile` flag.
    func readAll() throws -> Contents {
        try withAccess { directory in
            var contents = Contents()
            let manager = FileManager.default
            let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []

            for name in names {
                let logical = Self.logicalName(of: name)
                guard logical.hasPrefix("peloton"), logical.hasSuffix(".json") else { continue }
                guard !logical.hasPrefix("peloton-backup-") else { continue }

                let url = directory.appendingPathComponent(logical)
                guard let data = readFile(at: url) else {
                    contents.hadUnreadableFile = true
                    continue
                }

                if logical == "peloton-sync.json" {
                    contents.legacy = String(data: data, encoding: .utf8)
                } else if let file = try? LogFile.decoded(from: data) {
                    guard file.format <= EventLog.currentFormat else {
                        // Written by a newer version of the app: we do not
                        // know how to interpret it, and ignoring it beats
                        // reading it wrong.
                        NSLog("Peloton — \(logical) is in format \(file.format), too recent")
                        contents.hadUnreadableFile = true
                        continue
                    }
                    contents.files.append(file)
                } else {
                    // File present but unreadable: we report it and never
                    // overwrite it — it belongs to another device.
                    NSLog("Peloton — unreadable journal file: \(logical)")
                    contents.hadUnreadableFile = true
                }
            }
            return contents
        }
    }

    // MARK: - Writing

    /// Publishes THIS device's log. `log` must already be filtered down to
    /// what we are allowed to write (see `EventLog.publishable(by:)`).
    func write(_ log: EventLog) throws {
        let file = LogFile(log: log,
                           deviceId: DeviceIdentity.id,
                           deviceName: DeviceIdentity.name)
        let data = try file.encoded()
        _ = try withAccess { directory in
            writeFile(data, to: directory.appendingPathComponent(myFileName))
        }
    }

    /// A dated copy of our own file, once a day, 2 days kept.
    ///
    /// This insures against the human slip ("I deleted everything"), not
    /// against a synchronisation failure — that one loses nothing by
    /// construction.
    func writeDailyBackupIfNeeded(_ log: EventLog) {
        // An empty log is not worth backing up — and above all, it must not
        // "consume" the day's backup. Without this line, the very first
        // publish (log still empty, before the old file was taken over) froze
        // a zero-fact backup for the whole day.
        guard !log.events.isEmpty else { return }
        let today = Self.dayStamp(Date())
        guard UserDefaults.standard.string(forKey: backupDayKey) != today else { return }
        guard let data = try? LogFile(log: log,
                                      deviceId: DeviceIdentity.id,
                                      deviceName: DeviceIdentity.name).encoded()
        else { return }

        let prefix = "peloton-backup-\(DeviceIdentity.fileToken)-"
        let wrote = (try? withAccess { directory -> Bool in
            guard writeFile(data, to: directory.appendingPathComponent("\(prefix)\(today).json"))
            else { return false }

            // We only tidy up OUR OWN backups.
            let manager = FileManager.default
            let mine = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? [])
                .map(Self.logicalName(of:))
                .filter { $0.hasPrefix(prefix) }
                .sorted()
            for stale in mine.dropLast(backupsKept) {
                try? manager.removeItem(at: directory.appendingPathComponent(stale))
            }
            return true
        }) ?? false

        // We only tick the day off if the backup truly exists: otherwise a
        // failed write would leave us without a net until tomorrow.
        if wrote { UserDefaults.standard.set(today, forKey: backupDayKey) }
    }

    // MARK: - Folder access

    /// Where the folder lives, for whoever needs the URL itself
    /// (the folder watcher). `nil` when no folder can be reached.
    ///
    /// The caller becomes responsible for "sandboxed" access
    /// (`startAccessingSecurityScopedResource`).
    func resolveURL() -> URL? { try? resolve().url }

    private func resolve() throws -> (url: URL, wasStale: Bool) {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            throw Failure.notConfigured
        }
        var isStale = false
        #if os(macOS)
        let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                           relativeTo: nil, bookmarkDataIsStale: &isStale)
        #else
        let url = try? URL(resolvingBookmarkData: bookmark,
                           relativeTo: nil, bookmarkDataIsStale: &isStale)
        #endif
        guard let url else { throw Failure.unreachable }
        return (url, isStale)
    }

    private func withAccess<T>(_ body: (URL) -> T) throws -> T {
        let (url, wasStale) = try resolve()
        if wasStale { remember(url) }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return body(url)
    }

    /// Coordinated read: `NSFileCoordinator` waits until iCloud has finished
    /// writing before letting us read, which keeps us from landing on a
    /// half-synchronised file.
    private func readFile(at url: URL) -> Data? {
        ensureDownloaded(url)
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [],
                                       error: &coordinationError) { readable in
            data = try? Data(contentsOf: readable)
        }
        if let coordinationError {
            NSLog("Peloton — read coordination: \(coordinationError)")
        }
        return data
    }

    @discardableResult
    private func writeFile(_ data: Data, to url: URL) -> Bool {
        var succeeded = false
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                       error: &coordinationError) { writable in
            do {
                try data.write(to: writable, options: .atomic)
                succeeded = true
            } catch {
                NSLog("Peloton — writing \(url.lastPathComponent) failed: \(error)")
            }
        }
        if let coordinationError {
            NSLog("Peloton — write coordination: \(coordinationError)")
        }
        return succeeded
    }

    /// Forces the download of a file still "in the cloud" and waits briefly
    /// for it to arrive.
    ///
    /// Without this, the app read ghost files (`.icloud`, zero-sized) and
    /// wrongly concluded that the folder was empty or broken.
    private func ensureDownloaded(_ url: URL, timeout: TimeInterval = 8) {
        guard let status = downloadStatus(of: url) else { return }
        guard status != .current else { return }

        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            if downloadStatus(of: url) == .current { return }
        }
        NSLog("Peloton — \(url.lastPathComponent) not downloaded by iCloud yet")
    }

    private func downloadStatus(of url: URL) -> URLUbiquitousItemDownloadingStatus? {
        try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
    }

    // MARK: - Small helpers

    /// The "logical" name of an iCloud file.
    ///
    /// A file that has not been downloaded yet shows up as
    /// `.peloton-a1b2c3d4.json.icloud` — same file, different name. We strip
    /// the leading dot and the suffix to recover the real name.
    private static func logicalName(of name: String) -> String {
        var clean = name
        if clean.hasSuffix(".icloud") { clean.removeLast(".icloud".count) }
        if clean.hasPrefix(".") { clean.removeFirst() }
        return clean
    }

    private static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
