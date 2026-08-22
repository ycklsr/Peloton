import WidgetKit
import SwiftUI
import os

// ─────────────────────────────────────────────────────────────────────────────
// THE READINGS
//
// One per local midnight, written by the HTML. This struct is the whole of what
// the widget knows — and notice that it does not know it is about a competitive
// exam. It has minutes, a target, and a number of days. Change what the widget
// says by changing the page that fills these in; there is nothing to recompile.
// ─────────────────────────────────────────────────────────────────────────────

private struct Reading: Decodable {
    let at: String        // "2026-08-15T00:00", local time
    let min: Int          // minutes credited that day
    let target: Int       // minutes PROMISED for that day; 0 = nothing promised
    let examDays: Int     // days left until the written exams
}

struct PelotonEntry: TimelineEntry {
    let date: Date
    let min: Int
    let target: Int
    let examDays: Int
}

// ─────────────────────────────────────────────────────────────────────────────
// THE PROVIDER
// ─────────────────────────────────────────────────────────────────────────────

struct PelotonProvider: TimelineProvider {

#if os(macOS)
    private static let appGroup = "LU2QMNTUKC.group.fr.yannick.crpe2027.Peloton"   // macOS wants the team prefix
#else
    private static let appGroup = "group.fr.yannick.crpe2027.Peloton"      // iOS wants it bare
#endif
    private static let fileName = "widget-plan.json"

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.timeZone = .current
        return f
    }()

    func placeholder(in context: Context) -> PelotonEntry {
        PelotonEntry(date: .now, min: 0, target: 0, examDays: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (PelotonEntry) -> Void) {
        completion(entries().first ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PelotonEntry>) -> Void) {
        let all = entries()
        guard !all.isEmpty else {
            completion(Timeline(entries: [placeholder(in: context)], policy: .after(.now.addingTimeInterval(3600))))
            return
        }
        /* Come back within the hour — not when the plan runs out, three weeks
           from now.
           Inside a single day the tile holds exactly one entry, so the minutes
           worked today reach it only when the app's explicit reload lands. That
           reload is the fast path and it is normally instant. But when one is
           lost, a policy pointing three weeks out means nothing else ever
           comes: at the next midnight the tile steps to the next entry of the
           stale timeline, which carries no minutes and no target, and it reads
           "0 min" every day until the plan expires.
           An hour bounds that. The app keeps the fast path; this only makes
           sure a tile that went wrong repairs itself. */
        completion(Timeline(entries: all, policy: .after(.now.addingTimeInterval(3600))))
    }

    /// The plan, plus a fortnight of extrapolation past its end.
    ///
    /// The plan covers a week. The app going unopened for longer than that must
    /// not leave a countdown frozen on a number that was true last Tuesday: a
    /// countdown that is wrong by three days is worse than no countdown, because
    /// you cannot tell which one you are looking at. Days are arithmetic, so
    /// they can be carried forward exactly; minutes cannot, and read zero —
    /// which is what "the app has not seen you work" honestly means.
    private func entries() -> [PelotonEntry] {
        let plan = readPlan()
        guard !plan.isEmpty else { return [] }

        var out: [PelotonEntry] = []
        for (i, reading) in plan.enumerated() {
            guard let date = Self.formatter.date(from: reading.at) else { continue }
            /* TODAY'S ENTRY IS STAMPED NOW, NOT AT MIDNIGHT.
               Every reading is written for a local midnight, and today's is the
               only one that changes during the day. Left on 00:00 it keeps the
               same date for sixteen hours — and WidgetKit caches a rendered
               tile against its entry's date, so a fresh timeline carrying new
               minutes was being answered with the picture drawn at midnight,
               when there was no commitment yet and nothing worked. The
               extension read the right number all day and the desktop showed
               "0 min".
               Stamping it at generation time gives every refresh a date the
               cache has never seen, which is what forces the repaint. */
            out.append(PelotonEntry(date: i == 0 ? Swift.max(date, Date()) : date,
                                    min: reading.min,
                                    target: reading.target, examDays: reading.examDays))
        }
        guard let last = out.last else { return [] }

        let calendar = Calendar.current
        for offset in 1...14 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: last.date),
                  last.examDays - offset >= 0 else { break }
            out.append(PelotonEntry(date: date, min: 0,
                                    target: last.target, examDays: last.examDays - offset))
        }
        return out
    }

    /// Reads the plan, and says so out loud when it cannot.
    ///
    /// The silent version of this cost days. The widget drew its placeholder,
    /// the file was plainly there, and nothing anywhere said the extension was
    /// being denied at `read` — the group identifier was in iOS form, which
    /// macOS resolves to a path and then refuses to open from any process but
    /// the one that made it. One line of logging named it in seconds.
    ///   log stream --predicate 'subsystem == "fr.yannick.crpe2027.Peloton"'
    private func readPlan() -> [Reading] {
        guard let url = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)?
                .appending(path: Self.fileName) else { return [] }
        do {
            let plan = try JSONDecoder().decode([Reading].self, from: Data(contentsOf: url))
            /* Say what was read, not only what failed. A tile showing stale
               minutes beside a file already holding the right ones is
               indistinguishable, from the outside, from a tile that never ran
               — and only one of those is a bug in this file. */
            os_log("readPlan: %d readings, first %{public}@ = %d min",
                   log: OSLog(subsystem: "fr.yannick.crpe2027.Peloton", category: "widget"),
                   type: .info, plan.count, plan.first?.at ?? "—", plan.first?.min ?? -1)
            return plan
        } catch {
            os_log("readPlan failed: %{public}@",
                   log: OSLog(subsystem: "fr.yannick.crpe2027.Peloton", category: "widget"),
                   type: .error, String(describing: error))
            return []
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// THE VIEWS
//
// Lock-screen widgets are rendered monochrome and tinted by the system: there
// is no colour to design with, so everything here reads in luminance alone.
// ─────────────────────────────────────────────────────────────────────────────

/// Minutes done over minutes promised, inside the ring. Never above full: going
/// past the promise closes the ring, it does not overflow it.
///
/// A day with no promise has no denominator to show. It prints the minutes
/// alone and leaves the ring empty — inventing a target would say the day was
/// measured against something, and it was not: a day nobody promised anything
/// for cannot count however long it is worked.
struct PelotonRing: View {
    let entry: PelotonEntry

    private var progress: Double {
        guard entry.target > 0 else { return 0 }
        return Swift.min(Double(entry.min) / Double(entry.target), 1)
    }

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Circle().stroke(.tertiary, lineWidth: 5).padding(2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.primary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(2)
            // The whole ratio on one line, the unit named once underneath it.
            // Repeating "min" on both sides of a ratio adds nothing — the unit
            // cannot differ between them — and it costs the type size that
            // makes the thing readable at a glance.
            VStack(spacing: -1) {
                Text(entry.target > 0 ? "\(entry.min)/\(entry.target)" : "\(entry.min)")
                    .font(.system(size: 15, weight: .medium))
                Text("min")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .minimumScaleFactor(0.6)   // three digits each side still fit
            .lineLimit(1)
            .padding(.horizontal, 7)
        }
    }
}

/// The countdown, filling the tile.
struct PelotonCountdown: View {
    let entry: PelotonEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ÉCRITS CRPE")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.1)
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.8)
                .lineLimit(1)
            Text("J-\(entry.examDays)")
                .font(.system(size: 36, weight: .medium))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

#if os(macOS)
/// The desktop tile. Not a lock-screen widget scaled up: it is `systemMedium`,
/// which is the width every other widget on the desktop uses, and it has room
/// for both readings side by side rather than one of them cropped to "ÉC…".
///
/// It also gets colour, which the lock screen does not — the same blue the app
/// draws your own curve in.
struct PelotonDesktop: View {
    @Environment(\.colorScheme) private var scheme
    let entry: PelotonEntry

    private var accent: Color {
        scheme == .dark ? Color(red: 0.302, green: 0.639, blue: 1.0)    // #4DA3FF
                        : Color(red: 0.145, green: 0.388, blue: 0.922)  // #2563EB
    }
    private var progress: Double {
        guard entry.target > 0 else { return 0 }
        return Swift.min(Double(entry.min) / Double(entry.target), 1)
    }

    var body: some View {
        HStack(spacing: 24) {
            ZStack {
                Circle().stroke(.tertiary, lineWidth: 9)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: -1) {
                    Text(entry.target > 0 ? "\(entry.min)/\(entry.target)" : "\(entry.min)")
                        .font(.system(size: 22, weight: .medium))
                        .monospacedDigit()
                    Text("min")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .minimumScaleFactor(0.55)
                .lineLimit(1)
                .padding(.horizontal, 11)
            }
            .frame(width: 98, height: 98)

            VStack(alignment: .leading, spacing: 1) {
                Text("ÉCRITS CRPE")
                    .font(.system(size: 12, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Text("J-\(entry.examDays)")
                    .font(.system(size: 46, weight: .medium))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }
}
#endif

struct PelotonWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PelotonEntry

    var body: some View {
        #if os(iOS)
        switch family {
        case .accessoryCircular:    PelotonRing(entry: entry)
        default:                    PelotonCountdown(entry: entry)
        }
        #else
        PelotonDesktop(entry: entry)
        #endif
    }
}

// ─────────────────────────────────────────────────────────────────────────────

struct PelotonWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: PelotonProvider()) { entry in
            PelotonWidgetView(entry: entry)
            // Lock-screen accessories are transparent by design; a desktop
            // tile needs the real surface under it, or it floats.
            #if os(iOS)
                .containerBackground(.clear, for: .widget)
            #else
                .containerBackground(.background, for: .widget)
            #endif
        }
        .configurationDisplayName("Peloton")
        .description("Ta séance du jour, et le compte à rebours des écrits.")
        .supportedFamilies(Self.families)
    }

    /// DO NOT change these to force a refresh. It looks like the way to make
    /// the system re-read a widget, and it is not: every tile already on a
    /// screen stores the kind it was placed with, so a new one orphans all of
    /// them — which is what happened here, silently, to two lock-screen
    /// widgets. What actually makes the system re-read a widget is a new
    /// CFBundleVersion, which both install scripts now stamp on every build.
    ///
    /// They differ per platform only because the two went through different
    /// histories: the Mac's desktop tile, and the descriptor cached for it,
    /// were both written during the episode above. A kind is just an
    /// identifier and placements are never shared across platforms, so
    /// letting each keep its own costs nothing and spares the tiles.
#if os(macOS)
    private static let kind = "PelotonWidget.v2"
#else
    private static let kind = "PelotonWidget"
#endif

    private static var families: [WidgetFamily] {
        #if os(iOS)
        [.accessoryCircular, .accessoryRectangular]
        #else
        // Medium only: it is the width the desktop is laid out on, and the
        // small square cannot hold both readings without cropping one.
        [.systemMedium]
        #endif
    }
}

@main
struct PelotonWidgetBundle: WidgetBundle {
    var body: some Widget { PelotonWidget() }
}
