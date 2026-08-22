import Foundation
import UserNotifications
import os

/// Schedules the peloton's reminders.
///
/// The HTML works out the plan ("Manon roule à 18 h 30"), the Swift lays it
/// down. The plan is always **replaced wholesale**, never added to: that is
/// what avoids ghost reminders left over from an expired plan.
@MainActor
enum NotificationScheduler {

    struct Item: Decodable {
        /// Local date and time, in the `2026-08-12T18:30` format.
        let at: String
        let title: String
        let body: String
    }

    /// Authorization is asked for only once, at launch.
    static func requestAuthorizationOnce() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Replaces every pending reminder with this plan.
    ///
    /// A newer plan arriving in the meantime makes this one give up: without
    /// that safeguard, two competing plans would interleave and leave behind a
    /// mixture of the two.
    /* SAY WHAT HAPPENED, ESPECIALLY WHEN NOTHING DID.
       Every way this function gives up was silent, and each of them leaves the
       previous plan standing — so a schedule from weeks ago keeps firing while
       the app looks like it is publishing normally. That is exactly what the
       widget's silent path cost, and the fix there was one line of logging.
         log stream --predicate 'subsystem == "fr.yannick.crpe2027.Peloton"' */
    private static let log = OSLog(subsystem: "fr.yannick.crpe2027.Peloton", category: "notif")

    static func replaceAll(with items: [Item]) async {
        generation += 1
        let mine = generation

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            os_log("replaceAll: GIVING UP, not authorized (status %d) — the old plan stays",
                   log: log, type: .error, settings.authorizationStatus.rawValue)
            return
        }
        guard mine == generation else {
            os_log("replaceAll: superseded before clearing (gen %d, now %d) — the old plan stays",
                   log: log, type: .info, mine, generation)
            return
        }

        /* NAMING THEM IS WHAT ACTUALLY REMOVES THEM.
           removeAllPendingNotificationRequests leaves orphans behind. A plan
           shorter than the one before it overwrites peloton-0…14 by identifier
           and the rest stay alive: peloton-18 and peloton-19 were still firing
           on 22 August, from a plan written weeks earlier, announcing sessions
           in a format the app no longer produces and naming a rival who had
           since been renamed. Both calls now, and the identifier sweep goes
           well past any plan this app can build (the cap is 60). */
        let before = await center.pendingNotificationRequests().count
        center.removePendingNotificationRequests(
            withIdentifiers: (0..<256).map { "peloton-\($0)" })
        center.removeAllPendingNotificationRequests()
        let after = await center.pendingNotificationRequests().count
        os_log("replaceAll: %d pending, %d left after clearing", log: log, type: .info, before, after)

        let now = Date()
        var added = 0
        for (index, item) in items.enumerated() {
            guard mine == generation else {
                os_log("replaceAll: superseded after %d of %d added — the list is left short",
                       log: log, type: .error, added, items.count)
                return
            }
            guard let date = formatter.date(from: item.at), date > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date)
            let request = UNNotificationRequest(
                identifier: "peloton-\(index)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            try? await center.add(request)
            added += 1
        }
        os_log("replaceAll: %d received, %d scheduled", log: log, type: .info, items.count, added)
    }

    private static var generation = 0

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = .current
        return formatter
    }()
}
