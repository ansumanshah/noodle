import Testing
@testable import NoodleCore

@Suite struct LogsRoutingTests {
    @Test func noArgumentsAndComponentNamesStayLocal() {
        #expect(LogsRouting.route([]) == .component)
        for name in ["engine", "linux", "privileged"] { #expect(LogsRouting.route([name]) == .component) }
    }

    @Test func componentOptionsStayLocal() {
        #expect(LogsRouting.route(["engine", "-n", "5"]) == .component)
        #expect(LogsRouting.route(["-n", "5", "linux"]) == .component)
        #expect(LogsRouting.route(["--tail", "20"]) == .component)
        #expect(LogsRouting.route(["--grep", "error", "engine", "--raw"]) == .component)
        #expect(LogsRouting.route(["--grep", "boot", "-f", "privileged"]) == .component)
        #expect(LogsRouting.route(["--follow"]) == .component)
    }

    @Test func containerNamesAreRejected() {
        #expect(LogsRouting.route(["web"]) == .invalid)
        #expect(LogsRouting.route(["-f", "--tail", "5", "web"]) == .invalid)
        #expect(LogsRouting.route(["web", "-f"]) == .invalid)
        #expect(LogsRouting.route(["--tail=5", "web"]) == .invalid)
        #expect(LogsRouting.route(["engine", "web"]) == .invalid)
    }

    @Test func aValueIsNeverReadAsAContainerName() {
        #expect(LogsRouting.route(["-n", "web"]) == .component)   // dies later as a bad number, not docker
        #expect(LogsRouting.route(["--grep", "web"]) == .component)
        #expect(LogsRouting.route(["--grep", "web", "engine"]) == .component)
        #expect(LogsRouting.route(["-n", "5", "--grep", "engine", "web"]) == .invalid)
    }

    @Test func dockerOnlyOptionsAreRejected() {
        #expect(LogsRouting.route(["--since", "5m", "web"]) == .invalid)
        #expect(LogsRouting.route(["--since=5m", "web"]) == .invalid)
        #expect(LogsRouting.route(["--until", "1h"]) == .invalid)
        #expect(LogsRouting.route(["-t", "web"]) == .invalid)
        #expect(LogsRouting.route(["--timestamps", "--details", "web"]) == .invalid)
    }
}

@Suite struct RemovedLogNamesTests {
    @Test func oldNamesAndAliasesAreRejected() {
        for name in ["daemon", "vm", "workload", "--filter", "--unknown"] {
            #expect(LogsRouting.route([name]) == .invalid)
        }
        #expect(LogsRouting.route(["engine", "linux"]) == .invalid)
        #expect(LogsRouting.route(["--grep"]) == .invalid)
    }
}
