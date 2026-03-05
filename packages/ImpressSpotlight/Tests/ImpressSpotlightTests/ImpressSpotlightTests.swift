import Testing
@testable import ImpressSpotlight

@Test func spotlightDomainConstants() {
    #expect(SpotlightDomain.paper == "com.impress.paper")
    #expect(SpotlightDomain.document == "com.impress.document")
    #expect(SpotlightDomain.figure == "com.impress.figure")
    #expect(SpotlightDomain.conversation == "com.impress.conversation")
    #expect(SpotlightDomain.task == "com.impress.task")
}
