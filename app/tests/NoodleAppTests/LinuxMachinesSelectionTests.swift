import Testing
@testable import NoodleApp

@MainActor @Suite struct LinuxMachinesSelectionTests {
    private func list(_ names: [String]) -> String {
        "[" + names.map {
            """
            {"name":"\($0)","state":"running","distro":"alpine","image":"alpine:3.22","cpus":1,"memoryMiB":512,"diskGiB":5}
            """
        }.joined(separator: ",") + "]"
    }

    @Test func explicitDestinationSurvivesCachedListAndFailedRefresh() async {
        var names = ["alpha"]
        var fails = false
        let store = LinuxMachinesStore { _, _ in
            CLI.Result(code: fails ? 1 : 0, output: fails ? "List failed" : self.list(names))
        }
        await store.refresh()
        let revision = store.listRevision
        #expect(store.validatedSelection("zeta", after: revision) == "zeta")
        fails = true
        await store.refresh()
        #expect(store.listRevision == revision)
        #expect(store.validatedSelection("zeta", after: revision) == "zeta")
        fails = false
        names.append("zeta")
        await store.refresh()
        #expect(store.validatedSelection("zeta", after: revision) == "zeta")
    }

    @Test func successfulUnchangedListValidatesMissingDestination() async {
        let store = LinuxMachinesStore { _, _ in CLI.Result(code: 0, output: self.list(["alpha"])) }
        await store.refresh()
        let revision = store.listRevision
        await store.refresh()
        #expect(store.listRevision > revision)
        #expect(store.validatedSelection("missing", after: revision) == "alpha")
        #expect(store.validatedSelection(nil, after: revision) == "alpha")
    }

    @Test func malformedListDoesNotValidateDestination() async {
        let store = LinuxMachinesStore { _, _ in CLI.Result(code: 0, output: "not json") }
        await store.refresh()
        #expect(store.listRevision == 0)
        #expect(store.validatedSelection("zeta", after: 0) == "zeta")
    }
}
