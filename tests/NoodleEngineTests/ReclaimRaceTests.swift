import Foundation
import Testing
@testable import NoodleVM
import NoodleCore

/// Holds the `balloon_hint` reply open so a test can land activity while the controller waits for the guest.
private actor HintGate {
    private var entered: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var isEntered = false

    func hint() async {
        isEntered = true
        entered?.resume(); entered = nil
        await withCheckedContinuation { release = $0 }
    }
    func waitEntered() async {
        if !isEntered { await withCheckedContinuation { entered = $0 } }
    }
    func open() { release?.resume(); release = nil }
}

@Suite struct ReclaimRaceTests {
    private func controller(used: UInt64?, gate: HintGate) async -> (VMController, NoodlePaths) {
        let paths = tempPaths()
        let vm = VMController(paths: paths, settings: VMSettings(cpus: 1, memoryMiB: 1024))
        var hooks = VMHooks()
        hooks.balloonHint = { await gate.hint(); return (0, used) }
        await vm.setHooks(hooks)
        return (vm, paths)
    }

    @Test func activityDuringTheGuestCallMeansNoInflate() async {
        let gate = HintGate()
        let (vm, paths) = await controller(used: 100 << 20, gate: gate)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let plan = Task { await vm.reclaimPlan() }
        await gate.waitEntered()
        await vm.noteActivity()
        await gate.open()
        #expect(await plan.value.target == nil)
    }

    @Test func quietGuestCallGivesATarget() async {
        let gate = HintGate()
        let (vm, paths) = await controller(used: 100 << 20, gate: gate)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let plan = Task { await vm.reclaimPlan() }
        await gate.waitEntered()
        await gate.open()
        #expect(await plan.value.target == VMController.balloonTarget(workingSet: 100 << 20))
    }

    @Test func unreportedUseMeansNoInflate() async {
        let gate = HintGate()
        let (vm, paths) = await controller(used: nil, gate: gate)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let plan = Task { await vm.reclaimPlan() }
        await gate.waitEntered()
        await gate.open()
        let result = await plan.value
        #expect(result.target == nil)
        #expect(!result.again)
    }
}
