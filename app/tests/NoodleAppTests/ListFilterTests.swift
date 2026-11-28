import Testing
@testable import NoodleApp

@Suite struct ListFilterTests {
    @Test func blankMatchesEverything() {
        #expect(ListFilter.matches("", "web"))
        #expect(ListFilter.matches("  ", nil))
    }
    @Test func matchesAnyFieldIgnoringCase() {
        #expect(ListFilter.matches("NGI", "web", "nginx:latest"))
        #expect(ListFilter.matches(" web ", "Web", nil))
        #expect(!ListFilter.matches("redis", "web", nil, "nginx"))
    }
}
