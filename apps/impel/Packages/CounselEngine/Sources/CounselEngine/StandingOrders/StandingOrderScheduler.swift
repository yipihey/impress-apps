import Foundation
import ImpressAI
import OSLog

/// Executes standing orders on their configured schedules.
///
/// Uses NativeAgentLoop for execution — fully App Store compliant.
public actor StandingOrderScheduler {
    private let logger = Logger(subsystem: "com.impress.impel", category: "counsel-scheduler")
    private let database: CounselDatabase
    private let nativeLoop: NativeAgentLoop
    private var schedulerTask: Task<Void, Never>?
    private let checkInterval: TimeInterval = 60

    public init(database: CounselDatabase, nativeLoop: NativeAgentLoop) {
        self.database = database
        self.nativeLoop = nativeLoop
    }

    /// Start the scheduler loop.
    public func start() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task {
            logger.info("Standing order scheduler started")
            while !Task.isCancelled {
                await checkAndExecuteDueOrders()
                try? await Task.sleep(for: .seconds(checkInterval))
            }
        }
    }

    /// Stop the scheduler.
    public func stop() {
        schedulerTask?.cancel()
        schedulerTask = nil
        logger.info("Standing order scheduler stopped")
    }

    private func checkAndExecuteDueOrders() async {
        do {
            let dueOrders = try database.fetchDueStandingOrders()
            for order in dueOrders {
                await executeOrder(order)
            }
        } catch {
            logger.error("Failed to check due orders: \(error.localizedDescription)")
        }
    }

    private func executeOrder(_ order: StandingOrder) async {
        logger.info("Executing standing order: \(order.description)")

        let systemPrompt = """
            You are counsel, executing a standing order for the impress research environment. \
            Complete the following task using the available tools. Be thorough but concise.
            """

        let messages = [AIMessage(role: .user, text: "Execute this standing order: \(order.description)")]

        let result = await nativeLoop.run(
            systemPrompt: systemPrompt,
            messages: messages,
            maxTurns: 10
        )

        logger.info("Standing order completed: \(order.description) (\(result.roundsUsed) rounds, \(result.toolExecutions.count) tools)")

        // Update last run time and calculate next run
        var updated = order
        updated.lastRunAt = Date()
        updated.nextRunAt = StandingOrderParser.nextRun(schedule: order.schedule, after: Date())
        do {
            try database.updateStandingOrder(updated)
        } catch {
            logger.error("Failed to update standing order: \(error.localizedDescription)")
        }
    }
}
