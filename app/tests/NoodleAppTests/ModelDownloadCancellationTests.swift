import Foundation
import NoodleCore
import Testing
@testable import NoodleApp

@MainActor @Suite struct ModelDownloadCancellationTests {
    @Test func cancellingDownloadDrainsRunnerAndRefreshesBeforeReleasingActivity() async {
        let store = ModelsPageStore(demo: false, chatHistory: ModelChatHistory())
        let started = AsyncStream<Void>.makeStream()
        let pendingDownload = AsyncStream<Void>.makeStream()
        let refreshing = AsyncStream<Void>.makeStream()
        let finishRefresh = AsyncStream<Void>.makeStream()
        defer {
            started.continuation.finish(); pendingDownload.continuation.finish()
            refreshing.continuation.finish(); finishRefresh.continuation.finish()
        }
        var runnerWasCancelled = false
        var didReload = false
        let request = Task {
            await store.runDownload("local", operation: { progress in
                progress(.init(phase: .downloading, receivedBytes: 10, totalBytes: 100))
                started.continuation.yield(())
                for await _ in pendingDownload.stream {}
                runnerWasCancelled = Task.isCancelled
                // A cancelling process can still deliver one last progress line while it exits.
                progress(.init(phase: .verifying, receivedBytes: 100, totalBytes: 100))
                return .init(code: 130, output: "Cancelled")
            }, reload: {
                didReload = true
                refreshing.continuation.yield(())
                for await _ in finishRefresh.stream {}
            })
        }
        var startedEvents = started.stream.makeAsyncIterator()
        _ = await startedEvents.next()
        #expect(store.activity == .command(.download("local")))
        #expect(store.downloadProgress?.receivedBytes == 10)
        store.cancelDownload()
        store.cancelDownload()
        #expect(store.cancellingDownload)
        var refreshEvents = refreshing.stream.makeAsyncIterator()
        _ = await refreshEvents.next()
        #expect(runnerWasCancelled)
        #expect(didReload)
        #expect(store.busy)
        #expect(store.cancellingDownload)
        #expect(store.downloadProgress == nil)
        #expect(store.problem == nil)
        var competingOperationRan = false
        await store.runDownload("other", operation: { _ in
            competingOperationRan = true
            return .init(code: 0, output: "")
        }, reload: {})
        await store.refresh()
        await store.perform(.stop)
        await store.runPrompt("Should wait", modelID: "local") { _, _, _ in competingOperationRan = true }
        #expect(!competingOperationRan)
        #expect(store.activity == .command(.download("local")))
        finishRefresh.continuation.finish()
        await request.value
        #expect(!store.busy)
        #expect(!store.cancellingDownload)
        #expect(store.downloadProgress == nil)
        #expect(store.problem == nil)
        await store.runDownload("local", operation: { _ in .init(code: 0, output: "") }, reload: {})
        #expect(store.problem == nil)
        #expect(!store.busy)
    }

    @Test func downloadFailureStaysRetryableAndStillRefreshes() async {
        let store = ModelsPageStore(demo: false, chatHistory: ModelChatHistory())
        var didReload = false
        await store.runDownload("local", operation: { _ in
            .init(code: 1, output: "noodle: Connection lost")
        }, reload: { didReload = true })
        #expect(didReload)
        #expect(store.problem?.title == "Download failed")
        #expect(store.problem?.detail == "Connection lost")
        #expect(store.problem?.retry == .download("local"))
        #expect(!store.busy)
        #expect(!store.cancellingDownload)
    }

    @Test func cancelDownloadDoesNotInterruptAnUnrelatedCommand() {
        let store = ModelsPageStore(demo: true, demoState: .starting)
        store.cancelDownload()
        #expect(store.activity == .command(.start("gemma4")))
        #expect(!store.cancellingDownload)
        #expect(store.problem == nil)
    }

    @Test func cancellingTheCallerAlsoCancelsItsOwnedDownload() async {
        let store = ModelsPageStore(demo: false, chatHistory: ModelChatHistory())
        let started = AsyncStream<Void>.makeStream()
        let pending = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish(); pending.continuation.finish() }
        var runnerWasCancelled = false
        var didReload = false
        let request = Task {
            await store.runDownload("local", operation: { _ in
                started.continuation.yield(())
                for await _ in pending.stream {}
                runnerWasCancelled = Task.isCancelled
                return .init(code: 130, output: "Cancelled")
            }, reload: { didReload = true })
        }
        var startedEvents = started.stream.makeAsyncIterator()
        _ = await startedEvents.next()
        request.cancel()
        await request.value
        #expect(runnerWasCancelled)
        #expect(!didReload)
        #expect(store.problem == nil)
        #expect(!store.busy)
        #expect(!store.cancellingDownload)
    }
}
