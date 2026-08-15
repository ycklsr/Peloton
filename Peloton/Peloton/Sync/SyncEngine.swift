import Foundation

// MARK: - What travels between Swift and the HTML

/// What the HTML receives after every operation: the complete log and the
/// state of the synchronisation.
///
/// We hand back the **whole** log every time, never a delta. That is
/// deliberate: after any call, the HTML holds exactly what Swift holds. No
/// divergence is possible, so no "partial update" bug can exist. The log of a
/// full CRPE preparation weighs a few hundred kilobytes — the luxury is
/// affordable.
nonisolated struct SyncSnapshot: Codable, Sendable {
    var events: [SyncEvent]
    var status: SyncStatus
    /// The old `peloton-sync.json`, if it is still in the folder. The HTML
    /// turns it into facts — see `LEGACY` in `duel-crpe-2027.html`.
    var legacy: String?
}

/// A fact waiting to be created. Swift gives it its identity (id, order,
/// device, time): the HTML has no business knowing the clock.
nonisolated struct EventDraft: Sendable {
    var kind: String
    var data: JSONValue

    /// Forced identity. **The one exception**, reserved for taking over the
    /// old file: both devices must then build bit-for-bit identical facts,
    /// otherwise the very same old session would end up existing twice. See
    /// `WebBridge.parseDrafts`.
    var pinned: Pinned?

    nonisolated struct Pinned: Sendable {
        var id: String
        var order: Int
        var device: String
    }
}

// MARK: - The engine

/// The conductor of the synchronisation — and the only object in the app that
/// decides anything at all about it.
///
/// ## The four rules
///
/// 1. **Every change is written locally first**, before any attempt towards
///    iCloud. An action therefore cannot be lost to a network problem: at
///    worst, it is late.
/// 2. **We write our own file only**, never another device's.
/// 3. **Merging means gathering facts** — never picking a winner, never
///    overwriting. See `EventLog.merging`.
/// 4. **Read/write ordering does not matter.** That is what makes the whole
///    family of bugs disappear that the old version tried to contain with a
///    dozen flags (`readyToPush`, `pageReady`, `__pulledOnce`, `__adopted`,
///    `__cycleReads`…). Those flags have no counterpart here because they
///    would have nothing left to do.
@MainActor
final class SyncEngine {

    /// The merged log as this device knows it: the facts born here and every
    /// one received from the others.
    ///
    /// Any change bumps `revision` — automatically, so that it cannot be
    /// forgotten the day someone adds a new write path.
    private var log: EventLog {
        didSet { if log != oldValue { revision += 1 } }
    }

    /// See `SyncStatus.revision`.
    private var revision = 0

    private var status = SyncStatus()

    /// The two possible causes of failure, kept apart.
    ///
    /// Without that separation, a successful publish erased the "a file in the
    /// folder could not be read" warning: the app then said nothing about a
    /// state that was in fact incomplete.
    private var readProblem: String?
    private var pushProblem: String?
    private let local = LocalStore()
    private let folder = SyncFolder()
    private let ioQueue = DispatchQueue(label: "fr.yannick.Peloton.sync", qos: .utility)

    /// Readable names of the devices met so far, kept from one session to the
    /// next so that the settings stay meaningful even when a file is
    /// momentarily unreadable.
    private var deviceNames: [String: String]

    private var watcher: FolderWatcher?
    private var pollTimer: Timer?
    private var isPollingFolder = false

    /// Called when the folder brought something new without us asking for it.
    var onRemoteChange: ((SyncSnapshot) -> Void)?

    init() {
        log = local.load()
        deviceNames = UserDefaults.standard
            .dictionary(forKey: Self.deviceNamesKey) as? [String: String] ?? [:]
        deviceNames[DeviceIdentity.id] = DeviceIdentity.name
        refreshStatus()
    }

    // MARK: - What the HTML calls

    /// The state as of right now, without a single read or write.
    ///
    /// This is what lets the app draw itself instantly at launch, even
    /// offline, and only then go and look at the folder.
    func snapshot() -> SyncSnapshot {
        SyncSnapshot(events: log.events, status: status, legacy: nil)
    }

    /// Records new facts, saves them, then tries to publish them.
    func append(_ drafts: [EventDraft]) async -> SyncSnapshot {
        guard !drafts.isEmpty else { return snapshot() }

        let born = drafts.enumerated().map { offset, draft -> SyncEvent in
            if let pinned = draft.pinned {
                return SyncEvent(id: pinned.id, order: pinned.order, device: pinned.device,
                                 time: Self.legacyTimeMarker, kind: draft.kind, data: draft.data)
            }
            return log.makeEvent(kind: draft.kind, data: draft.data, sequence: offset)
        }

        log = log.appending(born)
        await saveLocally()          // ← safety first…
        await publish()              // ← …sharing second
        return snapshot()
    }

    /// Re-reads the folder and merges whatever is found there.
    @discardableResult
    func pull() async -> SyncSnapshot {
        guard folder.isConfigured else {
            refreshStatus()
            return snapshot()
        }

        var legacy: String?
        switch await runIO({ [folder] in ReadOutcome(reading: folder) }) {

        case .failed(let reason):
            readProblem = reason

        case .read(let files, let legacyFile, let hadUnreadableFile):
            for file in files { deviceNames[file.deviceId] = file.deviceName }
            rememberDeviceNames()

            let merged = EventLog.merging([log] + files.map(\.log))
            let broughtSomethingNew = merged != log
            log = merged
            legacy = legacyFile

            readProblem = hadUnreadableFile
                ? "Un fichier du dossier n'a pas pu être lu (iCloud ne l'a peut-être pas encore téléchargé)."
                : nil
            status.lastPullAt = Self.nowInMilliseconds

            if broughtSomethingNew { await saveLocally() }

            // Does the folder already know all of OUR facts? If not (first
            // publish, failed write, file deleted by hand), we publish again.
            // This is the system's only "catch-up", and it carries no risk:
            // republishing already-known facts changes nothing.
            let mineInFolder = files.first { $0.deviceId == DeviceIdentity.id }?.log
            if mineInFolder != log.publishable(by: DeviceIdentity.id) {
                await publish()
            } else {
                status.awaitingPush = false   // the folder already has our facts
            }
        }

        refreshStatus()
        var result = snapshot()
        result.legacy = legacy
        return result
    }

    /// The user has just picked the shared folder.
    func adoptFolder(_ url: URL) async -> SyncSnapshot {
        folder.remember(url)
        startWatching()
        return await pull()
    }

    /// A complete reset, **on every device**.
    ///
    /// The subtlety: the erasure is itself a fact, and it propagates. The
    /// HTML's projection ignores everything preceding the last `pelotonReset`.
    /// The other device therefore resets itself on its own at its next
    /// synchronisation, without us ever touching its file.
    ///
    /// This is also what fixes the old "resetting resurrects the data" defect:
    /// there is nothing left to erase, only a fact to append — and an appended
    /// fact is never forgotten.
    func resetEverything() async -> SyncSnapshot {
        log = EventLog([log.makeEvent(kind: "pelotonReset", data: .object([:]))])
        await saveLocally()
        await publish()
        refreshStatus()
        return snapshot()
    }

    // MARK: - Watching the folder

    /// Starts both detection mechanisms: the system notification (immediate
    /// but fallible) and the periodic poll (slow but dependable).
    func startWatching(pollInterval: TimeInterval = 15) {
        stopWatching()
        if let url = folder.resolveURL() {
            watcher = FolderWatcher(url: url) { [weak self] in
                Task { @MainActor in await self?.pullAndNotify() }
            }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pullAndNotify() }
        }
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pullAndNotify() async {
        // Reading the folder can take a while (iCloud is downloading). Later
        // polls wait their turn rather than piling up.
        guard !isPollingFolder else { return }
        isPollingFolder = true
        defer { isPollingFolder = false }

        let before = log
        let snapshot = await pull()
        // We only wake the interface if the folder really brought something:
        // a poll that finds nothing must stay invisible.
        if log != before { onRemoteChange?(snapshot) }
    }

    // MARK: - Writes

    private func saveLocally() async {
        let log = log
        await runIO { [local] in local.save(log) }
    }

    /// Publishes our facts to the folder. Never throws: a failure becomes a
    /// message visible in the app, not an exception to catch somewhere else.
    private func publish() async {
        guard folder.isConfigured else {
            status.awaitingPush = true
            refreshStatus()
            return
        }
        let mine = log.publishable(by: DeviceIdentity.id)
        let problem = await runIO { [folder] () -> String? in
            do {
                try folder.write(mine)
                folder.writeDailyBackupIfNeeded(mine)
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription
                    ?? "Publication vers le dossier impossible."
            }
        }

        status.awaitingPush = problem != nil
        pushProblem = problem
        if problem == nil { status.lastPushAt = Self.nowInMilliseconds }
        refreshStatus()
    }

    // MARK: - Status

    private func refreshStatus() {
        status.revision = revision
        // The write failure wins: "your last action is not in the folder yet"
        // is more urgent than "a file could not be read".
        status.problem = pushProblem ?? readProblem
        status.hasFolder = folder.isConfigured
        status.deviceName = DeviceIdentity.name
        status.eventCount = log.events.count

        var counts: [String: Int] = [:]
        var lastSeen: [String: String] = [:]
        for event in log.events {
            counts[event.device, default: 0] += 1
            lastSeen[event.device] = event.time   // the log is sorted: the last one wins
        }
        status.contributors = counts.keys.sorted().map { deviceId in
            SyncStatus.Contributor(
                name: deviceNames[deviceId] ?? Self.unknownDeviceName(deviceId),
                isThisDevice: deviceId == DeviceIdentity.id,
                eventCount: counts[deviceId] ?? 0,
                lastActivity: lastSeen[deviceId])
        }
    }

    // MARK: - Small helpers

    /// The result of reading the folder, in a form that can travel from one
    /// thread to another (hence no `Error` type, which cannot).
    nonisolated private enum ReadOutcome: Sendable {
        case read(files: [LogFile], legacy: String?, hadUnreadableFile: Bool)
        case failed(reason: String)

        init(reading folder: SyncFolder) {
            do {
                let contents = try folder.readAll()
                self = .read(files: contents.files,
                             legacy: contents.legacy,
                             hadUnreadableFile: contents.hadUnreadableFile)
            } catch {
                self = .failed(reason: (error as? LocalizedError)?.errorDescription
                               ?? "Dossier de synchronisation illisible.")
            }
        }
    }

    /// Runs blocking work (files, iCloud) off the interface thread, so the app
    /// never freezes.
    private func runIO<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: work()) }
        }
    }

    private func rememberDeviceNames() {
        UserDefaults.standard.set(deviceNames, forKey: Self.deviceNamesKey)
    }

    private static let deviceNamesKey = "peloton.sync.deviceNames"

    /// Facts coming from the old file carry this marker instead of a time:
    /// they predate the existence of the log.
    private static let legacyTimeMarker = "1970-01-01T00:00:00Z"

    private static var nowInMilliseconds: Double { Date().timeIntervalSince1970 * 1000 }

    private static func unknownDeviceName(_ deviceId: String) -> String {
        deviceId == "legacy" ? "Ancienne sauvegarde" : "Appareil inconnu"
    }
}
