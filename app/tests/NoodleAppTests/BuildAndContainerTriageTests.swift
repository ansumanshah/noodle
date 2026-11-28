import Testing
@testable import NoodleApp

struct BuildAndContainerTriageTests {
    @Test func parsesInterleavedBuildProgressAndPreservesOutput() {
        let steps = BuildProgressStep.parse("""
        #1 [internal] load metadata
        #2 [1/2] FROM alpine
        #1 DONE 0.2s
        #2 CACHED
        #3 [2/2] RUN false
        #3 0.1 problem
        #3 ERROR: process failed
        """)
        #expect(steps.map(\.id) == [1, 2, 3])
        #expect(steps[0].status == "Done")
        #expect(steps[0].duration == "0.2s")
        #expect(steps[1].status == "Cached")
        #expect(steps[2].status == "Failed")
        #expect(steps[2].output.contains("#3 0.1 problem"))
        #expect(BuildProgressStep.parse("old log without progress").isEmpty)
    }

    @Test func statusBucketsUseExitCodeAndRunningState() {
        func container(_ state: String, _ status: String) -> ContainerSummary {
            ContainerSummary(id: state + status, names: [], image: "", state: state, status: status, created: 0)
        }
        let running = container("running", "Up 1 minute")
        let stopped = container("exited", "Exited (0) 1 minute ago")
        let failed = container("exited", "Exited (137) 1 minute ago")
        #expect(ContainerStatusFilter.running.matches(running))
        #expect(ContainerStatusFilter.stopped.matches(stopped))
        #expect(ContainerStatusFilter.failed.matches(failed))
        #expect(!ContainerStatusFilter.stopped.matches(failed))
        #expect(ContainerStatusFilter.failed.matches(container("dead", "Dead")))
        #expect(ContainerStatusFilter.all.matches(failed))
    }
}

@Suite struct CLIFailureMessageTests {
    @Test func keepsTheToolsReasonAndSaysWhereToSeeMore() {
        let text = CLI.CommandError.readable("\nnoodle: build not found\nusage: …\n", status: 1, command: ["noodle", "builds", "inspect", "x"])
        #expect(text == "build not found. Run “noodle builds inspect x” in Terminal for details.")
    }

    @Test func fallsBackToTheExitStatus() {
        let text = CLI.CommandError.readable("  \n", status: 3, command: ["noodle", "builds", "list"])
        #expect(text.hasPrefix("The command stopped with status 3."))
    }
}
