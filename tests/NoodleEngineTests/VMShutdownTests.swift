import Foundation
import Testing
@testable import NoodleVM
@testable import NoodleEngine

private actor UnresponsiveShutdown {
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var stopWaiter: CheckedContinuation<Void, Never>?
    private var stopped = false
    private(set) var forced = false

    func request(blocked: Bool) async {
        if blocked, !stopped { await withCheckedContinuation { requestWaiter = $0 } }
    }
    func wait() async {
        if !stopped { await withCheckedContinuation { stopWaiter = $0 } }
    }
    func force() {
        forced = true; stopped = true
        requestWaiter?.resume(); requestWaiter = nil
        stopWaiter?.resume(); stopWaiter = nil
    }
}

@Suite struct VMShutdownTests {
    @Test func disconnectedShutdownDoesNotReconnectOrBoot() async {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let vm = VMController(paths: paths, settings: VMSettings(cpus: 2, memoryMiB: 1024))
        let guest = GuestClient(vm: vm)
        await #expect(throws: GuestError.self) { try await guest.call(GuestOp.shutdown, boot: false) }
        #expect(await vm.state == .stopped)
        #expect(await vm.bootCount == 0)
    }

    @Test(arguments: [true, false])
    func deadlineCoversBothAcknowledgementAndPowerOff(blockedRequest: Bool) async {
        let guest = UnresponsiveShutdown()
        await VMShutdown.run(timeout: .milliseconds(20), request: {
            await guest.request(blocked: blockedRequest)
        }, wait: { await guest.wait() }, force: { await guest.force() })
        #expect(await guest.forced)
    }
}
