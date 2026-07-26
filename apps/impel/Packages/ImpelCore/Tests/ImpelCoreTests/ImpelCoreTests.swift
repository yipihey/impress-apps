import Foundation
import Testing
@testable import ImpelCore

// MARK: - Thread State

@Test func threadStateTerminalClassification() {
    #expect(ThreadState.complete.isTerminal)
    #expect(ThreadState.killed.isTerminal)
    for state in [ThreadState.embryo, .active, .blocked, .review] {
        #expect(!state.isTerminal, "\(state.rawValue) is not a terminal state")
    }
}

@Test func threadTemperatureBuckets() {
    func level(_ temperature: Double) -> TemperatureLevel {
        ResearchThread(title: "t", temperature: temperature).temperatureLevel
    }
    #expect(level(0.0) == .cold)
    #expect(level(0.29) == .cold)
    #expect(level(0.3) == .warm)      // boundary is inclusive
    #expect(level(0.69) == .warm)
    #expect(level(0.7) == .hot)       // boundary is inclusive
    #expect(level(1.0) == .hot)
}

@Test func threadRoundTripsThroughCodable() throws {
    let thread = ResearchThread(
        id: "thread-1",
        title: "Dark matter halo profiles",
        description: "Compare NFW and Einasto fits",
        state: .review,
        temperature: 0.8,
        claimedBy: "scout",
        artifactCount: 3
    )
    let data = try JSONEncoder().encode(thread)
    let decoded = try JSONDecoder().decode(ResearchThread.self, from: data)

    #expect(decoded.id == thread.id)
    #expect(decoded.title == thread.title)
    #expect(decoded.state == .review)
    #expect(decoded.claimedBy == "scout")
    #expect(decoded.artifactCount == 3)
    #expect(decoded.temperatureLevel == .hot)
}

// MARK: - System State

@Test func systemStateFiltersByStatus() {
    let now = Date()
    let state = SystemState(
        threads: [
            ResearchThread(id: "a", title: "a", state: .active),
            ResearchThread(id: "b", title: "b", state: .embryo),
            ResearchThread(id: "c", title: "c", state: .active),
        ],
        agents: [
            Agent(id: "ag1", agentType: .research, status: .working),
            Agent(id: "ag2", agentType: .research, status: .idle),
        ],
        personas: [],
        escalations: [
            Escalation(id: "e1", category: .decision, priority: 1,
                       status: .pending, title: "low", description: "", createdBy: "ag1"),
            Escalation(id: "e2", category: .decision, priority: 9,
                       status: .pending, title: "high", description: "", createdBy: "ag1"),
            Escalation(id: "e3", category: .decision, priority: 5,
                       status: .resolved, title: "done", description: "", createdBy: "ag1"),
        ],
        suggestions: [],
        isPaused: false,
        lastUpdated: now
    )

    #expect(state.activeThreads.map(\.id) == ["a", "c"])
    #expect(state.workingAgents.map(\.id) == ["ag1"])
    // Pending only, highest priority first.
    #expect(state.pendingEscalations.map(\.id) == ["e2", "e1"])
    #expect(state.threadsByState[.active]?.count == 2)
}

// MARK: - Tool Policies

@Test func toolAccessImpliesReadWriteExecute() {
    #expect(!ToolAccess.none.canRead)
    #expect(ToolAccess.read.canRead)
    #expect(!ToolAccess.read.canWrite)
    #expect(ToolAccess.readWrite.canWrite)
    #expect(ToolAccess.full.canExecute)
}

@Test func toolPolicySetFallsBackToDefaultAccess() {
    let policies = ToolPolicySet(
        policies: [
            ToolPolicy(tool: "imbib", access: .readWrite),
            ToolPolicy(tool: "impart", access: .none),
        ],
        defaultAccess: .read
    )

    #expect(policies.canAccess("imbib"))
    #expect(policies.canWrite("imbib"))

    // An explicit .none policy overrides the permissive default.
    #expect(!policies.canAccess("impart"))
    #expect(!policies.canWrite("impart"))

    // Unlisted tools inherit defaultAccess.
    #expect(policies.canAccess("imprint"))
    #expect(!policies.canWrite("imprint"))
}

// MARK: - Personas

@Test func mockPersonasAreWellFormed() {
    let personas = Persona.mockPersonas()
    #expect(!personas.isEmpty)
    #expect(Set(personas.map(\.id)).count == personas.count, "persona ids must be unique")

    for persona in personas {
        #expect(!persona.name.isEmpty)
        #expect(!persona.systemPrompt.isEmpty)
        #expect((0.0...1.0).contains(persona.behavior.verbosity))
        #expect((0.0...1.0).contains(persona.behavior.riskTolerance))
        #expect((0.0...2.0).contains(persona.model.temperature))
        #expect(persona.systemImage == persona.archetype.systemImage)
    }
}

@Test func personaDelegatesToolChecksToItsPolicySet() throws {
    let persona = try #require(Persona.mockPersonas().first)
    #expect(persona.canUse(tool: "imbib") == persona.tools.canAccess("imbib"))
    #expect(persona.canWrite(tool: "imbib") == persona.tools.canWrite("imbib"))
}

@Test func personaRoundTripsThroughCodable() throws {
    let persona = try #require(Persona.mockPersonas().first)
    let data = try JSONEncoder().encode(persona)
    let decoded = try JSONDecoder().decode(Persona.self, from: data)

    #expect(decoded.id == persona.id)
    #expect(decoded.archetype == persona.archetype)
    #expect(decoded.behavior.workingStyle == persona.behavior.workingStyle)
    #expect(decoded.tools.defaultAccess == persona.tools.defaultAccess)
    #expect(decoded.tools.policies.count == persona.tools.policies.count)
}
