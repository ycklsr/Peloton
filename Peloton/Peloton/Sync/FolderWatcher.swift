import Foundation

/// Signals as soon as another device has written into the shared folder.
///
/// This is the "immediate" mechanism: the system wakes us up when a file in
/// the folder changes, without our having to ask for anything. It is
/// deliberately treated as a **bonus** — iCloud does not always notify (app
/// asleep, file that landed during a network outage). `SyncEngine` therefore
/// keeps a periodic safety poll running alongside it.
///
/// The old version had only the poll, every 60 seconds: two devices open at
/// the same time took up to a minute to see each other.
nonisolated final class FolderWatcher: NSObject, NSFilePresenter {

    /// The watched folder. Immutable: to change folder, throw this watcher
    /// away and create another one. That immutability is what lets the system
    /// read this property from any thread without risk.
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue

    private let onChange: @Sendable () -> Void
    private let hasSecurityScope: Bool

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.presentedItemURL = url
        self.onChange = onChange
        self.hasSecurityScope = url.startAccessingSecurityScopedResource()

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        self.presentedItemOperationQueue = queue

        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    /// Call before releasing the watcher. Do not forget: a presenter left
    /// registered slows down every file operation on the system.
    func stop() {
        NSFileCoordinator.removeFilePresenter(self)
        if hasSecurityScope { presentedItemURL?.stopAccessingSecurityScopedResource() }
    }

    // MARK: System notifications (delivered on `presentedItemOperationQueue`)

    func presentedItemDidChange() { onChange() }
    func presentedSubitemDidChange(at url: URL) { onChange() }
    func presentedSubitemDidAppear(at url: URL) { onChange() }
}
