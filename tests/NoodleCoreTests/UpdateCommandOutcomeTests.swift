import Testing
@testable import NoodleCore

@Suite struct UpdateCommandOutcomeTests {
    @Test func successfulSwapWithFailedRestartStillRelaunchesAndKeepsTheError() {
        let outcome = UpdateCommandOutcome(code: 3, output: "engine did not restart\n")
        #expect(outcome == .installed(restartError: "engine did not restart"))
    }

    @Test func successfulInstallNeedsNoRestartWarning() {
        #expect(UpdateCommandOutcome(code: 0, output: "installed\n") == .installed(restartError: nil))
    }

    @Test(arguments: [Int32(1), 2, 126, 127])
    func failedInstallationKeepsItsError(code: Int32) {
        #expect(UpdateCommandOutcome(code: code, output: "install failed\n") == .failed("install failed"))
    }
}
