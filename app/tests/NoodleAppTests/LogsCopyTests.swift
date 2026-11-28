import Testing
@testable import NoodleApp

@MainActor
struct LogsCopyTests {
    private func entry(_ text: String, _ level: LogLevel = .info) -> LogEntry {
        LogEntry(stderr: false, time: nil, text: text, level: level)
    }

    @Test func copyAllJoinsEveryLineWhenUnfiltered() {
        let m = LogsModel()
        m.append([entry("one"), entry("two"), entry("three")])
        #expect(m.plainText == "one\ntwo\nthree")
    }

    @Test func newLinesAreFilteredIncrementallyAndQueryIsTrimmed() {
        let m = LogsModel()
        m.query = "  get "
        m.refilter()
        m.append([entry("GET /a"), entry("post /b")])
        m.append([entry("get /c")])
        #expect(m.plainText == "GET /a\nget /c")
        #expect(m.total == 3)
    }

    @Test func queryChangeIsDebounced() async throws {
        let m = LogsModel()
        m.append([entry("alpha"), entry("beta")])
        m.query = "alpha"
        #expect(m.visible.count == 2)
        // Poll: a fixed sleep flakes when the machine is loaded.
        for _ in 0..<30 where m.plainText != "alpha" { try await Task.sleep(for: .milliseconds(100)) }
        #expect(m.plainText == "alpha")
    }

    @Test func copyAllRespectsTextAndLevelFilters() {
        let m = LogsModel()
        m.append([entry("GET /a"), entry("boom", .error), entry("get /b")])
        m.query = "get"
        m.refilter()
        #expect(m.plainText == "GET /a\nget /b")
        m.query = ""
        m.minLevel = .error
        #expect(m.plainText == "boom")
    }
}
