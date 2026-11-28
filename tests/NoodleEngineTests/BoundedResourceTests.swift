import Foundation
import Testing
@testable import NoodleVM
@testable import NoodleEngine
@testable import NoodleCore

@Suite struct BoundedResourceTests {
    @Test func concurrentEnsureRunningSharesOneColdBoot() async {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let vm = VMController(paths: paths, settings: VMSettings(cpus: 1, memoryMiB: 512))
        await vm.setBootGate { try? await Task.sleep(for: .milliseconds(200)) }
        async let a: Void? = try? await vm.ensureRunning()
        async let b: Void? = try? await vm.ensureRunning()
        _ = await (a, b)
        #expect(await vm.coldBootAttempts == 1)
    }

    @Test func slowEventSubscriberIsDisconnectedAtTheBufferLimit() async {
        let hub = EventHub()
        let stream = hub.subscribe()
        let total = EventHub.subscriberBuffer * 3
        for i in 0..<total {
            hub.publish(EventMessage(Type: "container", Action: "start", Actor: EventActor(ID: "x", Attributes: [:]), time: 1, timeNano: Int64(i)))
        }
        var received = 0
        for await _ in stream { received += 1 }
        #expect(received <= EventHub.subscriberBuffer)
        #expect(hub.subscriberCount == 0)
    }
}
