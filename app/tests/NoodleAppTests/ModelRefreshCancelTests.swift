import Foundation
import Testing
@testable import NoodleApp

/// A refresh stopped by the page (view task cancelled, overlapping refresh) comes back from the runner as exit 130.
/// That must never show as the "Couldn't refresh Models" banner.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ModelRefreshCancelTests {
    @Test func cancelledRefreshExit130RaisesNoProblemAndTheNextRefreshLoads() async {
        let store = ModelsPageStore(demo: false)
        store.runCommand = { _, _ in CLI.Result(code: 130, output: "Command cancelled.") }
        await store.refresh()
        #expect(store.problem == nil)
        #expect(store.activity == nil)

        store.runCommand = { args, _ in
            CLI.Result(code: 0, output: args.contains("catalog") ? "[]" : #"{"phase":"stopped"}"#)
        }
        await store.refresh()
        #expect(store.problem == nil)
    }

    @Test func realFailureStillRaisesTheBanner() async {
        let store = ModelsPageStore(demo: false)
        store.runCommand = { _, _ in CLI.Result(code: 1, output: "noodle: boom") }
        await store.refresh()
        #expect(store.problem?.detail == "boom")
    }
}
