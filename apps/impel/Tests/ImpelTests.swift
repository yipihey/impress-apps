import XCTest
@testable import ImpelCore

final class ImpelTests: XCTestCase {
    func testThreadStateDisplayNames() {
        XCTAssertEqual(ThreadState.embryo.displayName, "Embryo")
        XCTAssertEqual(ThreadState.active.displayName, "Active")
        XCTAssertEqual(ThreadState.blocked.displayName, "Blocked")
        XCTAssertEqual(ThreadState.review.displayName, "Review")
        XCTAssertEqual(ThreadState.complete.displayName, "Complete")
        XCTAssertEqual(ThreadState.killed.displayName, "Killed")
    }

    func testThreadStateTerminal() {
        XCTAssertFalse(ThreadState.embryo.isTerminal)
        XCTAssertFalse(ThreadState.active.isTerminal)
        XCTAssertFalse(ThreadState.blocked.isTerminal)
        XCTAssertFalse(ThreadState.review.isTerminal)
        XCTAssertTrue(ThreadState.complete.isTerminal)
        XCTAssertTrue(ThreadState.killed.isTerminal)
    }

    func testResearchThreadCreation() {
        let thread = ResearchThread(
            title: "Test Thread",
            description: "Test description"
        )

        XCTAssertEqual(thread.title, "Test Thread")
        XCTAssertEqual(thread.description, "Test description")
        XCTAssertEqual(thread.state, .embryo)
        XCTAssertEqual(thread.temperature, 0.5)
        XCTAssertNil(thread.claimedBy)
    }

    func testTemperatureLevel() {
        var thread = ResearchThread(title: "Test", temperature: 0.8)
        XCTAssertEqual(thread.temperatureLevel, .hot)

        thread = ResearchThread(title: "Test", temperature: 0.5)
        XCTAssertEqual(thread.temperatureLevel, .warm)

        thread = ResearchThread(title: "Test", temperature: 0.2)
        XCTAssertEqual(thread.temperatureLevel, .cold)
    }

    func testAgentTypeCapabilities() {
        XCTAssertEqual(AgentType.research.displayName, "Research")
        XCTAssertEqual(AgentType.code.displayName, "Code")
        XCTAssertEqual(AgentType.verification.displayName, "Verification")
    }

    func testSystemStateComputed() {
        let threads = [
            ResearchThread(title: "T1", state: .active),
            ResearchThread(title: "T2", state: .active),
            ResearchThread(title: "T3", state: .blocked),
        ]

        let agents = [
            Agent(id: "a1", agentType: .research, status: .working),
            Agent(id: "a2", agentType: .code, status: .idle),
        ]

        let escalations = [
            Escalation(category: .decision, priority: 5, title: "E1", description: "", createdBy: "test"),
        ]

        let state = SystemState(threads: threads, agents: agents, escalations: escalations)

        XCTAssertEqual(state.activeThreads.count, 2)
        XCTAssertEqual(state.workingAgents.count, 1)
        XCTAssertEqual(state.pendingEscalations.count, 1)
    }
}
