import Foundation

// Lightweight reading statistics persisted in UserDefaults.
enum ReadingStats {
    private static let secondsKey = "stats_totalSeconds"
    private static let daysKey    = "stats_readingDays"

    static var totalSeconds: Double {
        UserDefaults.standard.double(forKey: secondsKey)
    }

    static var readingDays: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: daysKey) ?? [])
    }

    /// Record a reading session of `seconds` and mark today as a reading day.
    static func record(seconds: Double) {
        guard seconds > 1 else { return }
        UserDefaults.standard.set(totalSeconds + seconds, forKey: secondsKey)
        var days = readingDays
        days.insert(todayKey())
        UserDefaults.standard.set(Array(days), forKey: daysKey)
    }

    /// Consecutive-day reading streak ending today (or yesterday).
    static var currentStreak: Int {
        let days = readingDays
        guard !days.isEmpty else { return 0 }
        let cal = Calendar.current
        var streak = 0
        var date = Date()
        // Allow the streak to count even if today hasn't been read yet.
        if !days.contains(key(for: date)) { date = cal.date(byAdding: .day, value: -1, to: date)! }
        while days.contains(key(for: date)) {
            streak += 1
            date = cal.date(byAdding: .day, value: -1, to: date)!
        }
        return streak
    }

    // MARK: - Helpers

    private static func todayKey() -> String { key(for: Date()) }

    private static func key(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
