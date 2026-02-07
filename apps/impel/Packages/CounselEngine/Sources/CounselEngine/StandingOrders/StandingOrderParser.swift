import Foundation

/// Parses natural language schedule descriptions into cron-like expressions
/// and calculates next run times.
public enum StandingOrderParser {

    /// Parse a natural language schedule into a cron-like expression.
    /// Supports: "every monday", "daily", "weekly", "every 2 hours", "every morning"
    public static func parse(_ text: String) -> String? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)

        // Daily patterns
        if lower.contains("every day") || lower.contains("daily") || lower.contains("each day") {
            return "0 9 * * *" // 9 AM daily
        }

        if lower.contains("every morning") {
            return "0 8 * * *"
        }

        if lower.contains("every evening") || lower.contains("every night") {
            return "0 18 * * *"
        }

        // Weekly patterns
        if lower.contains("weekly") || lower.contains("every week") {
            return "0 9 * * 1" // Monday 9 AM
        }

        let dayMap: [(String, String)] = [
            ("monday", "1"), ("tuesday", "2"), ("wednesday", "3"),
            ("thursday", "4"), ("friday", "5"), ("saturday", "6"), ("sunday", "0"),
        ]
        for (day, cron) in dayMap {
            if lower.contains("every \(day)") {
                return "0 9 * * \(cron)"
            }
        }

        // Hourly patterns
        if let match = lower.range(of: #"every (\d+) hours?"#, options: .regularExpression) {
            let numberStr = lower[match].components(separatedBy: .whitespaces)[1]
            if let hours = Int(numberStr), hours > 0, hours <= 24 {
                return "0 */\(hours) * * *"
            }
        }

        if lower.contains("hourly") || lower.contains("every hour") {
            return "0 * * * *"
        }

        // Monthly
        if lower.contains("monthly") || lower.contains("every month") {
            return "0 9 1 * *" // First of month, 9 AM
        }

        return nil
    }

    /// Calculate the next run time from a cron-like expression.
    /// Simple implementation covering common patterns.
    public static func nextRun(schedule: String, after date: Date) -> Date? {
        let components = schedule.split(separator: " ")
        guard components.count == 5 else { return nil }

        let calendar = Calendar.current
        var candidate = calendar.date(byAdding: .minute, value: 1, to: date)!

        // Simple: find next matching time by stepping forward
        for _ in 0..<(365 * 24 * 60) {
            let dc = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
            if matches(schedule: schedule, components: dc) {
                return candidate
            }
            candidate = calendar.date(byAdding: .minute, value: 1, to: candidate)!
        }

        return nil
    }

    private static func matches(schedule: String, components dc: DateComponents) -> Bool {
        let parts = schedule.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return false }

        return matchField(parts[0], value: dc.minute ?? 0) &&
               matchField(parts[1], value: dc.hour ?? 0) &&
               matchField(parts[2], value: dc.day ?? 0) &&
               matchField(parts[3], value: dc.month ?? 0) &&
               matchField(parts[4], value: (dc.weekday ?? 1) - 1) // Calendar weekday is 1-based
    }

    private static func matchField(_ field: String, value: Int) -> Bool {
        if field == "*" { return true }

        // Step values: */N
        if field.hasPrefix("*/"), let step = Int(field.dropFirst(2)), step > 0 {
            return value % step == 0
        }

        // Exact value
        if let exact = Int(field) {
            return value == exact
        }

        return false
    }
}
