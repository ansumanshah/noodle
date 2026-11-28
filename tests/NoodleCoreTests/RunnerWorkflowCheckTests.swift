import Foundation
import Testing
@testable import NoodleCore

@Suite struct RunnerWorkflowCheckTests {
    static let yaml = """
    name: ci
    on: push
    jobs:
      macos-label:
        runs-on: [self-hosted, noodle, macos]
        steps:
          - run: make
      custom-label:
        runs-on: [self-hosted, noodle, custom]
        steps:
          - run: make
      mac-ready:
        runs-on: [self-hosted, noodle-macos, xcode-26]
        steps:
          - run: xcodebuild test
      own-mac:
        runs-on: [self-hosted, macos]
        steps:
          - run: xcodebuild test
      reusable:
        uses: acme/shared/.github/workflows/ci.yml@main
    """

    @Test func checkAgreesWithTheHelpersLabelRule() {
        let found = Dictionary(uniqueKeysWithValues: WorkflowCheck.check(yaml: Self.yaml, file: "ci.yml", xcodeMajor: "26").map { ($0.job, $0) })
        #expect(found["macos-label"]?.kind == .other && found["macos-label"]?.suggestion == "[self-hosted, noodle-macos]")
        #expect(found["custom-label"]?.kind == .other && found["custom-label"]?.suggestion == "[self-hosted, noodle]")
        #expect(found["mac-ready"]?.kind == .ready)
        // Without that Xcode the helper would not take it either.
        #expect(WorkflowCheck.check(yaml: Self.yaml, file: "ci.yml", xcodeMajor: "25").first { $0.job == "mac-ready" }?.kind == .other)
    }

    @Test func selfHostedMacIsAnotherRunnerNotGitHub() {
        let f = WorkflowCheck.check(yaml: Self.yaml, file: "ci.yml").first { $0.job == "own-mac" }
        #expect(f?.kind == .other && f?.suggestion == nil)
    }

    @Test func reusableWorkflowIsNotComputed() {
        #expect(WorkflowCheck.check(yaml: Self.yaml, file: "ci.yml").first { $0.job == "reusable" }?.kind == .reusable)
    }
}
