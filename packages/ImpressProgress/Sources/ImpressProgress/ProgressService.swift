//
//  ProgressService.swift
//  ImpressProgress
//
//  Tracks research progress and milestones across the impress suite.
//  Provides subtle, non-gamified progress indicators.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.impress.progress", category: "progress")

// MARK: - Progress Types

/// A research milestone that can be tracked.
public enum MilestoneType: String, Codable, Sendable {
    case papersRead
    case readingStreak
    case writingMilestone
    case annotationsMade
    case citationsAdded
}

/// A recorded milestone achievement.
public struct Milestone: Identifiable, Codable, Sendable {
    public let id: UUID
    public let type: MilestoneType
    public let value: Int
    public let achievedAt: Date
    public let message: String

    public init(id: UUID = UUID(), type: MilestoneType, value: Int, achievedAt: Date = Date(), message: String) {
        self.id = id
        self.type = type
        self.value = value
        self.achievedAt = achievedAt
        self.message = message
    }
}

/// Daily reading activity record.
public struct DailyActivity: Codable, Sendable {
    public let date: Date
    public var papersRead: Int
    public var readingMinutes: Int
    public var annotationsMade: Int

    public init(date: Date = Date(), papersRead: Int = 0, readingMinutes: Int = 0, annotationsMade: Int = 0) {
        self.date = Calendar.current.startOfDay(for: date)
        self.papersRead = papersRead
        self.readingMinutes = readingMinutes
        self.annotationsMade = annotationsMade
    }
}

/// Progress summary for display.
public struct ProgressSummary: Sendable {
    public let currentStreak: Int
    public let longestStreak: Int
    public let totalPapersRead: Int
    public let papersThisWeek: Int
    public let papersThisMonth: Int
    public let recentMilestones: [Milestone]

    public init(
        currentStreak: Int = 0,
        longestStreak: Int = 0,
        totalPapersRead: Int = 0,
        papersThisWeek: Int = 0,
        papersThisMonth: Int = 0,
        recentMilestones: [Milestone] = []
    ) {
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.totalPapersRead = totalPapersRead
        self.papersThisWeek = papersThisWeek
        self.papersThisMonth = papersThisMonth
        self.recentMilestones = recentMilestones
    }
}

// MARK: - Progress Service

/// Service for tracking and celebrating research progress.
///
/// The progress service:
/// - Records daily reading and writing activity
/// - Calculates streaks and trends
/// - Generates milestone achievements
/// - Persists data to UserDefaults for cross-session continuity
///
/// Design philosophy: Subtle encouragement, not gamification.
/// No badges, points, or competitive elements. Just gentle
/// acknowledgment of consistent effort.
@MainActor @Observable
public final class ProgressService {

    // MARK: - Singleton

    public static let shared = ProgressService()

    // MARK: - Constants

    private static let activityKey = "com.impress.progress.dailyActivity"
    private static let milestonesKey = "com.impress.progress.milestones"
    private static let preferencesKey = "com.impress.progress.preferences"

    /// Milestone thresholds for papers read
    private static let paperMilestones = [10, 25, 50, 100, 250, 500, 1000]

    /// Milestone thresholds for reading streaks (days)
    private static let streakMilestones = [7, 14, 30, 60, 100, 365]

    // MARK: - Published State

    /// Current progress summary.
    public private(set) var summary: ProgressSummary = ProgressSummary()

    /// Most recent milestone (for display).
    public private(set) var latestMilestone: Milestone?

    /// Whether progress tracking is enabled.
    public var isEnabled: Bool {
        didSet {
            savePreferences()
        }
    }

    // MARK: - Private State

    private var dailyActivities: [DailyActivity] = []
    private var milestones: [Milestone] = []
    private let defaults: UserDefaults

    // MARK: - Initialization

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = true
        loadData()
        updateSummary()
    }

    // MARK: - Recording Activity

    /// Record that a paper was marked as read.
    public func recordPaperRead() {
        guard isEnabled else { return }

        ensureTodayActivity()

        if var today = todayActivity {
            today.papersRead += 1
            updateActivity(today)

            logger.info("Recorded paper read. Total today: \(today.papersRead)")

            // Check for milestones
            checkPaperMilestones()
            checkStreakMilestones()
        }

        updateSummary()
        saveData()
    }

    /// Record reading time.
    public func recordReadingTime(minutes: Int) {
        guard isEnabled else { return }

        ensureTodayActivity()

        if var today = todayActivity {
            today.readingMinutes += minutes
            updateActivity(today)

            logger.debug("Recorded \(minutes) minutes reading. Total today: \(today.readingMinutes)")
        }

        updateSummary()
        saveData()
    }

    /// Record an annotation made.
    public func recordAnnotation() {
        guard isEnabled else { return }

        ensureTodayActivity()

        if var today = todayActivity {
            today.annotationsMade += 1
            updateActivity(today)
        }

        saveData()
    }

    /// Record a writing milestone (words written).
    public func recordWritingProgress(words: Int) {
        guard isEnabled else { return }

        // Writing milestones: 1000, 5000, 10000, 25000, 50000 words
        let milestoneThresholds = [1000, 5000, 10000, 25000, 50000]

        for threshold in milestoneThresholds {
            if words >= threshold && !hasMilestone(.writingMilestone, value: threshold) {
                let message = formatWritingMilestone(words: threshold)
                addMilestone(type: .writingMilestone, value: threshold, message: message)
            }
        }

        saveData()
    }

    // MARK: - Queries

    /// Get activity for the past N days.
    public func recentActivity(days: Int) -> [DailyActivity] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return dailyActivities
            .filter { $0.date >= cutoff }
            .sorted { $0.date > $1.date }
    }

    /// Get papers read trend (count per day for past N days).
    public func papersTrend(days: Int) -> [(date: Date, count: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        return (0..<days).map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            let activity = dailyActivities.first { calendar.isDate($0.date, inSameDayAs: date) }
            return (date: date, count: activity?.papersRead ?? 0)
        }.reversed()
    }

    /// Dismiss the latest milestone notification.
    public func dismissLatestMilestone() {
        latestMilestone = nil
    }

    // MARK: - Private Methods

    private var todayActivity: DailyActivity? {
        let today = Calendar.current.startOfDay(for: Date())
        return dailyActivities.first { Calendar.current.isDate($0.date, inSameDayAs: today) }
    }

    private func ensureTodayActivity() {
        let today = Calendar.current.startOfDay(for: Date())
        if !dailyActivities.contains(where: { Calendar.current.isDate($0.date, inSameDayAs: today) }) {
            dailyActivities.append(DailyActivity(date: today))
        }
    }

    private func updateActivity(_ activity: DailyActivity) {
        if let index = dailyActivities.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: activity.date) }) {
            dailyActivities[index] = activity
        }
    }

    private func updateSummary() {
        let streak = calculateCurrentStreak()
        let longest = calculateLongestStreak()
        let total = dailyActivities.reduce(0) { $0 + $1.papersRead }
        let thisWeek = papersInPeriod(days: 7)
        let thisMonth = papersInPeriod(days: 30)
        let recent = milestones.suffix(5).reversed()

        summary = ProgressSummary(
            currentStreak: streak,
            longestStreak: longest,
            totalPapersRead: total,
            papersThisWeek: thisWeek,
            papersThisMonth: thisMonth,
            recentMilestones: Array(recent)
        )
    }

    private func calculateCurrentStreak() -> Int {
        let calendar = Calendar.current
        var streak = 0
        var date = calendar.startOfDay(for: Date())

        // Check if today has activity, if not start from yesterday
        if !hasActivityOn(date) {
            date = calendar.date(byAdding: .day, value: -1, to: date)!
        }

        while hasActivityOn(date) {
            streak += 1
            date = calendar.date(byAdding: .day, value: -1, to: date)!
        }

        return streak
    }

    private func calculateLongestStreak() -> Int {
        guard !dailyActivities.isEmpty else { return 0 }

        let calendar = Calendar.current
        let sorted = dailyActivities
            .filter { $0.papersRead > 0 }
            .sorted { $0.date < $1.date }

        guard !sorted.isEmpty else { return 0 }

        var longest = 1
        var current = 1

        for i in 1..<sorted.count {
            let prev = sorted[i - 1].date
            let curr = sorted[i].date
            let diff = calendar.dateComponents([.day], from: prev, to: curr).day ?? 0

            if diff == 1 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 1
            }
        }

        return longest
    }

    private func hasActivityOn(_ date: Date) -> Bool {
        dailyActivities.contains { activity in
            Calendar.current.isDate(activity.date, inSameDayAs: date) && activity.papersRead > 0
        }
    }

    private func papersInPeriod(days: Int) -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return dailyActivities
            .filter { $0.date >= cutoff }
            .reduce(0) { $0 + $1.papersRead }
    }

    private func checkPaperMilestones() {
        let total = dailyActivities.reduce(0) { $0 + $1.papersRead }

        for threshold in Self.paperMilestones {
            if total >= threshold && !hasMilestone(.papersRead, value: threshold) {
                let message = formatPaperMilestone(count: threshold)
                addMilestone(type: .papersRead, value: threshold, message: message)
            }
        }
    }

    private func checkStreakMilestones() {
        let streak = calculateCurrentStreak()

        for threshold in Self.streakMilestones {
            if streak >= threshold && !hasMilestone(.readingStreak, value: threshold) {
                let message = formatStreakMilestone(days: threshold)
                addMilestone(type: .readingStreak, value: threshold, message: message)
            }
        }
    }

    private func hasMilestone(_ type: MilestoneType, value: Int) -> Bool {
        milestones.contains { $0.type == type && $0.value == value }
    }

    private func addMilestone(type: MilestoneType, value: Int, message: String) {
        let milestone = Milestone(type: type, value: value, message: message)
        milestones.append(milestone)
        latestMilestone = milestone

        logger.info("New milestone: \(message)")
    }

    private func formatPaperMilestone(count: Int) -> String {
        switch count {
        case 10: return "You've read 10 papers"
        case 25: return "25 papers down"
        case 50: return "50 papers - building expertise"
        case 100: return "100 papers read"
        case 250: return "250 papers - deep knowledge"
        case 500: return "500 papers - exceptional"
        case 1000: return "1000 papers - remarkable dedication"
        default: return "\(count) papers read"
        }
    }

    private func formatStreakMilestone(days: Int) -> String {
        switch days {
        case 7: return "One week reading streak"
        case 14: return "Two weeks of consistent reading"
        case 30: return "A month of daily reading"
        case 60: return "Two months strong"
        case 100: return "100 days of reading"
        case 365: return "A year of daily reading"
        default: return "\(days) day reading streak"
        }
    }

    private func formatWritingMilestone(words: Int) -> String {
        switch words {
        case 1000: return "First 1,000 words written"
        case 5000: return "5,000 words - solid progress"
        case 10000: return "10,000 words - substantial work"
        case 25000: return "25,000 words - major milestone"
        case 50000: return "50,000 words - impressive output"
        default: return "\(words.formatted()) words written"
        }
    }

    // MARK: - Persistence

    private func loadData() {
        // Load daily activities
        if let data = defaults.data(forKey: Self.activityKey),
           let activities = try? JSONDecoder().decode([DailyActivity].self, from: data) {
            dailyActivities = activities
        }

        // Load milestones
        if let data = defaults.data(forKey: Self.milestonesKey),
           let stored = try? JSONDecoder().decode([Milestone].self, from: data) {
            milestones = stored
        }

        // Load preferences
        if let data = defaults.data(forKey: Self.preferencesKey),
           let prefs = try? JSONDecoder().decode([String: Bool].self, from: data) {
            isEnabled = prefs["enabled"] ?? true
        }

        // Clean up old data (keep 90 days)
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        dailyActivities = dailyActivities.filter { $0.date >= cutoff }
    }

    private func saveData() {
        // Save daily activities
        if let data = try? JSONEncoder().encode(dailyActivities) {
            defaults.set(data, forKey: Self.activityKey)
        }

        // Save milestones
        if let data = try? JSONEncoder().encode(milestones) {
            defaults.set(data, forKey: Self.milestonesKey)
        }
    }

    private func savePreferences() {
        let prefs = ["enabled": isEnabled]
        if let data = try? JSONEncoder().encode(prefs) {
            defaults.set(data, forKey: Self.preferencesKey)
        }
    }
}
