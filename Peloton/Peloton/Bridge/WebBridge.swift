import SwiftUI
import WebKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The bridge between the HTML page and the Swift — the single point of contact
/// between the two worlds.
///
/// ## How the roles are shared
///
/// - The **HTML** knows the domain: what a session, a chapter, a milestone
///   is. It decides *which events* to record.
/// - The **Swift** knows nothing of the domain. It carries opaque events:
///   it timestamps them, orders them, merges them, writes them, reads them back.
///
/// A direct and deliberate consequence: **adding a feature to the peloton
/// requires no change to the Swift.** The whole domain fits in a single
/// file, `duel-crpe-2027.html`.
///
/// ## The contract, in one sentence
///
/// The HTML calls `window.webkit.messageHandlers.peloton.postMessage({call, payload})`
/// and gets back **the entirety** of what the Swift knows. There is no such
/// thing as a partial update, hence no possible divergence between the two
/// sides.
@MainActor
final class WebBridge: NSObject {

    /// The name of the message handler, on the JavaScript side.
    static let handlerName = "peloton"

    weak var webView: WKWebView?

    private let engine: SyncEngine
    private let preferences = LocalPreferences()

    init(engine: SyncEngine) {
        self.engine = engine
        super.init()
        // The folder moved of its own accord: push what is new to the page,
        // without it having asked for anything.
        engine.onRemoteChange = { [weak self] snapshot in
            self?.push(snapshot)
        }
    }

    // MARK: - What the page receives

    /// The envelope returned by every call: everything the Swift holds.
    nonisolated struct Reply: Codable, Sendable {
        var events: [SyncEvent]
        var status: SyncStatus
        /// Present only once, while the old `peloton-sync.json` is still in the
        /// folder and has not been converted yet.
        var legacy: String?
        /// The settings that belong to this device (stopwatch, last opening).
        var local: [String: JSONValue]
    }

    private func reply(for snapshot: SyncSnapshot) -> Reply {
        Reply(events: snapshot.events,
              status: snapshot.status,
              legacy: snapshot.legacy,
              local: preferences.all())
    }

    /// Unprompted send to the page (the folder brought something new).
    ///
    /// The JSON travels as base64: an exotic device name therefore cannot
    /// break the snippet of JavaScript being injected.
    private func push(_ snapshot: SyncSnapshot) {
        guard let json = Self.encode(reply(for: snapshot)),
              let base64 = json.data(using: .utf8)?.base64EncodedString()
        else { return }
        webView?.evaluateJavaScript(
            "window.Peloton && window.Peloton.receiveFromNative('\(base64)')",
            completionHandler: nil)
    }

    // MARK: - Folder selection

    /// Opens the system folder picker.
    ///
    /// Presented straight through UIKit / AppKit rather than SwiftUI's
    /// `.fileImporter`: attached to the web view, that one had **no effect
    /// whatsoever on iOS** — the app asked for a folder that had become
    /// impossible to give it. It also matches the rest of this bridge, which
    /// already presents its alerts and its share sheet that way.
    func presentFolderPicker() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choisir ce dossier"
        panel.message = "Choisis le dossier partagé qui portera ton peloton d'un appareil à l'autre."
        // `begin` and not `runModal`: the main thread is not blocked while the
        // page waits for the answer to its call.
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.adopt(url) }
        }
        #else
        guard let root = Self.rootViewController else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = self
        root.present(picker, animated: true)
        #endif
    }

    private func adopt(_ url: URL) async {
        push(await engine.adoptFolder(url))
    }

    /// Starts/stops watching the folder depending on whether the app is in the
    /// foreground or not.
    func setActive(_ isActive: Bool) {
        if isActive {
            engine.startWatching()
            Task { push(await engine.pull()) }
        } else {
            engine.stopWatching()
        }
    }

    // MARK: - Utilities

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - The calls coming from the HTML

extension WebBridge: WKScriptMessageHandlerWithReply {

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any],
              let call = body["call"] as? String
        else {
            replyHandler(nil, "Appel mal formé (il faut un objet { call, payload }).")
            return
        }
        let payload = JSONValue(any: body["payload"] ?? NSNull()) ?? .null

        switch call {

        // — "Data" calls: they all answer with the complete envelope —

        case "snapshot":
            // The state already known, with no I/O at all: this is what lets
            // the app show up instantly, offline included.
            answer(with: engine.snapshot(), to: replyHandler)

        case "append":
            let drafts = Self.parseDrafts(payload)
            Task { [engine] in answer(with: await engine.append(drafts), to: replyHandler) }

        case "pull":
            Task { [engine] in answer(with: await engine.pull(), to: replyHandler) }

        case "reset":
            Task { [engine] in answer(with: await engine.resetEverything(), to: replyHandler) }

        case "setLocalPreference":
            if let key = payload["key"]?.stringValue {
                preferences.set(key, to: payload["value"] ?? .null)
            }
            answer(with: engine.snapshot(), to: replyHandler)

        case "chooseFolder":
            // Answer first (the page does not wait for the user's decision),
            // then open the picker; the folder that gets chosen makes its way
            // back to the page through `push`.
            answer(with: engine.snapshot(), to: replyHandler)
            presentFolderPicker()

        // — "Side effect" calls: nothing to return —

        case "scheduleNotifications":
            let items = Self.decode([NotificationScheduler.Item].self, from: payload) ?? []
            Task { await NotificationScheduler.replaceAll(with: items) }
            replyHandler(nil, nil)

        case "publishWidget":
            // Passed straight through, unread: what is in there is the page's
            // business, not ours.
            WidgetSnapshot.publish(payload)
            replyHandler(nil, nil)

        default:
            replyHandler(nil, "Appel inconnu : \(call)")
        }
    }

    private func answer(with snapshot: SyncSnapshot,
                        to replyHandler: @escaping (Any?, String?) -> Void) {
        guard let json = Self.encode(reply(for: snapshot)) else {
            replyHandler(nil, "Réponse impossible à sérialiser.")
            return
        }
        replyHandler(json, nil)
    }

    /// Turns what the page sends into event drafts.
    ///
    /// The `pinned` field is only used when taking over the old save file: it
    /// forces the identity of the event so that **two devices importing the
    /// same old file build exactly the same events**, and therefore so that
    /// they deduplicate instead of piling up.
    private static func parseDrafts(_ payload: JSONValue) -> [EventDraft] {
        guard case .array(let items) = payload else { return [] }
        return items.compactMap { item in
            guard let kind = item["kind"]?.stringValue else { return nil }
            var draft = EventDraft(kind: kind, data: item["data"] ?? .object([:]), pinned: nil)
            if let pinned = item["pinned"],
               let id = pinned["id"]?.stringValue,
               let device = pinned["device"]?.stringValue,
               case .number(let order)? = pinned["order"] {
                draft.pinned = EventDraft.Pinned(id: id, order: Int(order), device: device)
            }
            return draft
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from payload: JSONValue) -> T? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Presentation (iOS)

#if !os(macOS)
extension WebBridge {

    /// The anchor point for native presentations: folder picker and alerts
    /// coming from the page.
    fileprivate static var rootViewController: UIViewController? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first(where: \.isKeyWindow)?.rootViewController
    }
}
#endif

// MARK: - Native dialogs

/// Without this delegate, `confirm()` and `alert()` are plainly ignored inside a
/// `WKWebView`: the "Tout effacer" button would stay inert and confirmation
/// prompts would silently answer "no".
extension WebBridge: WKUIDelegate {

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Annuler")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
        #else
        guard let root = Self.rootViewController else { completionHandler(false); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Annuler", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        root.present(alert, animated: true)
        #endif
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
        #else
        guard let root = Self.rootViewController else { completionHandler(); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        root.present(alert, animated: true)
        #endif
    }
}

// MARK: - Folder picker callback (iOS)

#if !os(macOS)
extension WebBridge: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        Task { await adopt(url) }
    }
}
#endif
