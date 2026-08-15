import Foundation
import UserNotifications

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
    static func replaceAll(with items: [Item]) async {
        generation += 1
        let mine = generation

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
        guard mine == generation else { return }

        center.removeAllPendingNotificationRequests()

        let now = Date()
        for (index, item) in items.enumerated() {
            guard mine == generation else { return }
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
        }
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
