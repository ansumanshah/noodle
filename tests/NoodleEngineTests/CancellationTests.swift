import Foundation
import Testing
@testable import NoodleEngine

private actor ReadCompletion {
    var finished = false
    func finish() { finished = true }
}

@Suite struct CancellationTests {
    private func until(_ predicate: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            await Task.yield()
        }
        return await predicate()
    }

    @Test func cancellingAnIdleReadReleasesItsChannel() async throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let channel = FDChannel(fd: pair[0])
        defer { channel.close(); close(pair[1]) }
        let completion = ReadCompletion()
        let read = Task {
            defer { Task { await completion.finish() } }
            do { _ = try await channel.read(); return false }
            catch { return error is CancellationError }
        }
        let waiting = await until { channel.lock.withLock { channel.waiter != nil } }
        #expect(waiting)
        read.cancel()
        let finished = await until { await completion.finished }
        channel.close() // Also releases the pre-fix waiter when the expectation fails.
        #expect(finished)
        #expect(await read.value)
    }

    @Test func cancellingAContainerWaitRemovesItsContinuation() async {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        let wait = Task { await engine.addWaiter("created", timeout: nil) }
        #expect(await until { await engine.exitWaiters["created"]?.isEmpty == false })
        wait.cancel()
        let removed = await until { await engine.exitWaiters.isEmpty }
        await engine.resumeWaiters("created", WaitResult(StatusCode: 0, Error: nil))
        _ = await wait.value
        #expect(removed)
    }

    @Test func shutdownReleasesContainerWaitsWithoutAnExitEvent() async throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        try await engine.start()
        let wait = Task { await engine.addWaiter("created", timeout: nil) }
        #expect(await until { await engine.exitWaiters["created"]?.isEmpty == false })
        await engine.shutdown()
        let removed = await engine.exitWaiters.isEmpty
        await engine.resumeWaiters("created", WaitResult(StatusCode: 0, Error: nil))
        _ = await wait.value
        #expect(removed)
    }

    @Test func cancelledWaitDoesNotReportASuccessfulContainerExit() async throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        try await engine.start()
        _ = try await makeImage(engine)
        var request = ContainerCreateRequest(); request.config.Image = "tiny"
        let container = try await engine.createContainer(name: nil, request: request).id
        let wait = Task { try await engine.waitContainer(container, condition: "next-exit") }
        #expect(await until { await engine.exitWaiters[container]?.isEmpty == false })
        wait.cancel()
        await #expect(throws: CancellationError.self) { try await wait.value }
        await engine.shutdown()
    }
}
