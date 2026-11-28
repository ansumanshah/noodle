import Testing
@testable import noodle

@Suite struct SetupContextSelectionTests {
    private let sock = "unix:///var/run/docker.sock"

    @Test func selectsWhenDefaultSocketIsDead() {
        #expect(setupShouldSelectNoodle(currentContext: "default", endpoint: sock, pingAnswered: false))
    }
    @Test func keepsWhenDefaultSocketAnswers() {
        #expect(!setupShouldSelectNoodle(currentContext: "default", endpoint: sock, pingAnswered: true))
    }
    @Test func keepsAnotherCurrentContext() {
        #expect(!setupShouldSelectNoodle(currentContext: "colima", endpoint: sock, pingAnswered: false))
        #expect(!setupShouldSelectNoodle(currentContext: "noodle", endpoint: sock, pingAnswered: false))
    }
    @Test func keepsAnotherEndpoint() {
        #expect(!setupShouldSelectNoodle(currentContext: "default", endpoint: "tcp://host:2375", pingAnswered: false))
    }
}
