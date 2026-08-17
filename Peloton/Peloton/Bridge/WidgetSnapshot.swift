import Foundation
import WidgetKit
import os

/// Hands the widget its readings — and never learns what they mean.
///
/// A widget extension is another process, and it has no WebView: it cannot run
/// `duel-crpe-2027.html`, so it cannot compute anything about the CRPE. Rather
/// than move a second copy of the model into Swift — which would drift from the
/// first the week after it was written — the HTML sends readings that are
/// already decided, and this side only puts the bytes where the widget can
/// reach them.
///
/// So the rule the whole project runs on survives the widget: adding something
/// to it stays a change to the HTML. This file never gets edited again.
@MainActor
enum WidgetSnapshot {

    /// The one thing the app and its widget have in common. macOS requires an
    /// App Group to carry the team identifier; iOS requires it not to. Get it
    /// wrong on macOS and the container still resolves, the file still gets
    /// written by the app that owns it, and every OTHER process in the group —
    /// the widget — is denied at read with a bare "Operation not permitted".
#if os(macOS)
    static let appGroup = "LU2QMNTUKC.group.fr.yannick.crpe2027.Peloton"
#else
    static let appGroup = "group.fr.yannick.crpe2027.Peloton"
#endif
    static let fileName = "widget-plan.json"

    /// The widget's `kind`, repeated here because the two targets cannot see
    /// each other's source. It MUST match PelotonWidget.kind exactly — naming
    /// the kind is what makes the reload land: reloadAllTimelines() is the
    /// documented call and it is the one that was silently doing nothing on
    /// macOS, leaving the desktop tile on a timeline computed hours earlier
    /// while the file beside it was already correct.
#if os(macOS)
    static let widgetKind = "PelotonWidget.v2"
#else
    static let widgetKind = "PelotonWidget"
#endif
    private static let log = OSLog(subsystem: "fr.yannick.crpe2027.Peloton", category: "widget")

    static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: fileName)
    }

    /// Replaces the plan wholesale, then asks WidgetKit to come and read it.
    ///
    /// Same discipline as the reminders: never added to, always replaced. A
    /// plan that was merged with the previous one would keep serving yesterday's
    /// readings for the days the new one no longer covers.
    static func publish(_ plan: JSONValue) {
        guard let url, let data = try? JSONEncoder().encode(plan) else { return }
        // Atomic write: a widget waking up in the middle of a partial one would
        // read a truncated file and fall back to its placeholder — which looks
        // exactly like "you have done nothing today".
        guard (try? data.write(to: url, options: .atomic)) != nil else {
            os_log("publish: write FAILED at %{public}@", log: log, type: .error, url.path)
            return
        }
        /* Both, in this order. reloadAllTimelines is the general call; naming
           the kind is the one that actually reaches a desktop tile. And a line
           in the log either way — diagnosing this took an afternoon precisely
           because the successful path said nothing, so there was no way to
           tell "the app never published" from "the widget never listened". */
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        WidgetCenter.shared.reloadAllTimelines()
        os_log("publish: %d bytes, reload asked for kind %{public}@",
               log: log, type: .info, data.count, widgetKind)
    }
}
