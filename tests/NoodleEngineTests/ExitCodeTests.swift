import Foundation
import Testing

@testable import noodle

@Suite("ExitCode")
struct ExitCodeTests {
    @Test func constantsAreDistinct() {
        #expect([ExitCode.failure, ExitCode.usage, ExitCode.engineDown] == [1, 2, 3])
    }

    @Test func errorsMapToTheirCode() {
        #expect(exitCode(for: CLIError.usage("bad")) == 2)
        #expect(exitCode(for: CLIError("failed")) == 1)
        #expect(exitCode(for: ImportError.engineDown("down")) == 3)
        #expect(exitCode(for: ImportError.usage("bad")) == 2)
        #expect(exitCode(for: NSError(domain: "x", code: 9)) == 1)
    }

    @Test func yesAliasesAnswerConfirmations() {
        for flag in ["--yes", "-y", "-f", "--force"] { #expect(hasYes(["name", flag])) }
        #expect(!hasYes(["name", "--json"]))
    }

    @Test func machineStatusTakesJSONButStartDoesNot() {
        #expect(machineNameUsageError(["status", "nope", "--json"]) == nil)
        #expect(machineNameUsageError(["start", "nope"]) == nil)
        #expect(machineNameUsageError(["start", "nope", "--json"]) != nil)
        #expect(machineNameUsageError(["stop"]) != nil)
    }
}
