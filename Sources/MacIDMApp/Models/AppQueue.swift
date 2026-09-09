import Foundation

/// A user-defined download queue with its own concurrency cap and optional
/// daily schedule. Tasks with a nil `queueID` belong to the implicit main
/// queue, which is bounded only by the global simultaneous-download setting.
///
/// The model mirrors the `Queue` table defined in the technical
/// specification (id, name, concurrency, orderMode) and extends it with the
/// schedule fields recommended by the competitor evaluation (AB Download
/// Manager / FluxDown both expose per-queue start/stop windows).
struct AppQueue: Codable, Identifiable, Hashable, Sendable {
    enum OrderMode: String, Codable, Sendable {
        /// Higher task priority first, then oldest first (main queue behavior).
        case priority
        /// Strict creation order, ignoring priority.
        case fifo
    }

    static let concurrencyRange = 1...16
    static let maximumNameLength = 64

    let id: UUID
    var name: String
    var concurrency: Int
    var orderMode: OrderMode
    /// User or schedule driven pause. A paused queue never auto-starts
    /// queued tasks; already running tasks are paused when the queue pauses.
    var isPaused: Bool
    /// Automatically pause the queue once it runs out of active and queued
    /// tasks, so a nightly queue does not immediately start new work the
    /// user adds during the day.
    var stopOnEmpty: Bool
    var scheduleEnabled: Bool
    /// Day-of-week bitmask, bit 0 = Monday … bit 6 = Sunday. 127 = every day.
    var scheduleDays: Int
    /// Window start as minutes after midnight (0...1439).
    var scheduleStartMinutes: Int
    /// Window end as minutes after midnight; nil runs until midnight.
    var scheduleStopMinutes: Int?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        concurrency: Int = 2,
        orderMode: OrderMode = .priority,
        isPaused: Bool = false,
        stopOnEmpty: Bool = false,
        scheduleEnabled: Bool = false,
        scheduleDays: Int = 127,
        scheduleStartMinutes: Int = 0,
        scheduleStopMinutes: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumNameLength))
        self.concurrency = Self.clampConcurrency(concurrency)
        self.orderMode = orderMode
        self.isPaused = isPaused
        self.stopOnEmpty = stopOnEmpty
        self.scheduleEnabled = scheduleEnabled
        self.scheduleDays = scheduleDays & 0x7F
        self.scheduleStartMinutes = Self.clampMinutes(scheduleStartMinutes)
        self.scheduleStopMinutes = scheduleStopMinutes.map(Self.clampMinutes)
        self.createdAt = createdAt
    }

    static func clampConcurrency(_ value: Int) -> Int {
        min(concurrencyRange.upperBound, max(concurrencyRange.lowerBound, value))
    }

    private static func clampMinutes(_ value: Int) -> Int {
        min(1439, max(0, value))
    }

    /// Pure schedule evaluation used by both the periodic scheduler and the
    /// unit tests. Returns whether the queue should be active at `date`
    /// according to its day-of-week bitmask and time window.
    func scheduleSaysActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard scheduleEnabled else { return true }
        let weekday = calendar.component(.weekday, from: date)
        // Calendar.weekday: 1 = Sunday ... 7 = Saturday; map to bit index
        // 0 = Monday ... 6 = Sunday.
        let bitIndex = (weekday + 5) % 7
        guard scheduleDays & (1 << bitIndex) != 0 else { return false }
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let now = hour * 60 + minute
        let stop = scheduleStopMinutes ?? 1440
        if scheduleStartMinutes <= stop {
            return now >= scheduleStartMinutes && now < stop
        }
        // Window crosses midnight (e.g. 22:00 → 06:00).
        return now >= scheduleStartMinutes || now < stop
    }

    var scheduleSummary: String {
        guard scheduleEnabled else { return String(localized: "未启用") }
        func time(_ minutes: Int) -> String {
            String(format: "%02d:%02d", minutes / 60, minutes % 60)
        }
        let dayNames = [
            String(localized: "一"), String(localized: "二"), String(localized: "三"),
            String(localized: "四"), String(localized: "五"), String(localized: "六"),
            String(localized: "日"),
        ]
        let days = (0..<7).filter { scheduleDays & (1 << $0) != 0 }.map { dayNames[$0] }
        // The weekday prefix exists only in the Chinese phrasing of the
        // template below; the English catalog translates the whole
        // weekday-list template to a bare "%@".
        let dayText =
            days.count == 7
            ? String(localized: "每天")
            : String(localized: "周\(days.joined())")
        let stopText = scheduleStopMinutes.map(time) ?? "24:00"
        return "\(dayText) \(time(scheduleStartMinutes))–\(stopText)"
    }
}
