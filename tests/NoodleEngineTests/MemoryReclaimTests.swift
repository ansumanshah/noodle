import Foundation
import Testing

@testable import NoodleEngine
@testable import noodle

@Suite("MemoryReclaim")
struct MemoryReclaimTests {
    @Test func modelIsUnloadedOnlyWhenIdleLongEnough() {
        let now = Date()
        #expect(modelIdleLongEnough(lastRequest: now.addingTimeInterval(-90), now: now, idleSeconds: 60))
        #expect(!modelIdleLongEnough(lastRequest: now.addingTimeInterval(-5), now: now, idleSeconds: 60))
        #expect(!modelIdleLongEnough(lastRequest: nil, now: now, idleSeconds: 60))
    }

    @Test func runningContainerBlocksVMSleep() async {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        await engine.addRunningContainer("busy")
        #expect(await engine.sleepVMsIfIdle() == false)
    }

    @Test func reclaimJSONShape() throws {
        let freed = memoryReclaimJSON(modelUnloaded: true, vmSlept: false, freedBytes: 42)
        #expect(freed["modelUnloaded"] as? Bool == true)
        #expect(freed["vmSlept"] as? Bool == false)
        #expect(freed["freedBytes"] as? UInt64 == 42)
        #expect(memoryReclaimJSON(modelUnloaded: false, vmSlept: false, freedBytes: nil)["freedBytes"] is NSNull)
    }
}

private extension Engine {
    func addRunningContainer(_ id: String) {
        var container = ContainerRecord(id: id, name: id, created: Date(), image: "test", imageID: "test",
                                        config: ContainerConfig(), hostConfig: HostConfig())
        container.status = .running
        containers[id] = container
    }
}
