import Foundation
import Testing
@testable import NoodleApp

@MainActor @Suite struct ModelStreamingPresentationTests {
    @Test func firstNonemptyDeltaIsImmediateAndPausedPendingTextFlushes() async {
        let clock = PresentationClock()
        let response = ModelPromptResponse(scheduler: clock.scheduler)
        let gate = PresentationGate()
        let run = Task {
            await response.run { emit in
                emit("")
                #expect(clock.count == 0)
                emit("first")
                #expect(response.text == "first")
                emit(" second")
                await gate.pause()
            }
        }
        await gate.started()
        #expect(response.state == .receiving)
        #expect(response.text == "first")
        #expect(clock.count == 1)
        clock.advance(by: 0.099)
        #expect(response.text == "first")
        clock.advance(by: 0.001)
        #expect(response.text == "first second")
        #expect(clock.count == 0)
        clock.advance(by: 5)
        #expect(clock.count == 0)
        gate.finish()
        await run.value
        #expect(response.state == .completed)
    }

    @Test func terminalDrainPreservesUnicodeWhitespaceAndOrder() async {
        let clock = PresentationClock()
        let response = ModelPromptResponse(scheduler: clock.scheduler)
        let deltas = ["  ", "e", "\u{301}", " 👩🏽‍💻", "\n```swift\n", "\tlet x = 1\n", "```\n"]
        await response.run { emit in deltas.forEach(emit) }
        #expect(response.text.utf8.elementsEqual(deltas.joined().utf8))
        #expect(response.state == .completed)
        #expect(clock.count == 0)
        clock.fireCancelled()
        #expect(response.text.utf8.elementsEqual(deltas.joined().utf8))
    }

    @Test func cancelDrainsPendingTextAndRejectsLateCallbacks() async {
        let clock = PresentationClock()
        let response = ModelPromptResponse(scheduler: clock.scheduler)
        let gate = PresentationGate()
        var retained: (@MainActor (String) -> Void)?
        let run = Task {
            await response.run { emit in
                retained = emit
                emit("first")
                emit(" buffered")
                await gate.pause()
                emit(" late")
            }
        }
        await gate.started()
        response.cancel()
        #expect(response.state == .cancelling)
        #expect(response.text == "first buffered")
        #expect(clock.count == 0)
        retained?(" outside cancelled task")
        await run.value
        #expect(response.state == .cancelled)
        #expect(response.text == "first buffered")
        clock.fireCancelled()
        #expect(response.text == "first buffered")
    }

    @Test func failureDrainsPendingTextWithoutLosingTheError() async {
        let clock = PresentationClock()
        let response = ModelPromptResponse(scheduler: clock.scheduler)
        await response.run { emit in
            emit("partial")
            emit(" response\n")
            throw ModelPromptError("Connection ended early.")
        }
        #expect(response.text == "partial response\n")
        #expect(response.state == .failed)
        #expect(response.failure == "Connection ended early.")
        #expect(clock.count == 0)
        await response.run { emit in emit(" "); emit("\n\t") }
        #expect(response.state == .failed)
        #expect(response.text == " \n\t")
        #expect(response.failure?.contains("empty response") == true)
    }

    @Test func earlierRunCallbacksCannotWriteIntoALaterRequest() async {
        let clock = PresentationClock()
        let response = ModelPromptResponse(scheduler: clock.scheduler)
        var retained: (@MainActor (String) -> Void)?
        await response.run { emit in
            retained = emit
            emit("old")
            emit(" buffered")
        }
        let gate = PresentationGate()
        let run = Task {
            await response.run { emit in
                emit("new")
                emit(" buffered")
                await gate.pause()
            }
        }
        await gate.started()
        retained?(" stale")
        clock.fireCancelled()
        #expect(response.text == "new")
        #expect(response.state == .receiving)
        clock.advance(by: 0.1)
        #expect(response.text == "new buffered")
        gate.finish()
        await run.value
        #expect(response.text == "new buffered")
        #expect(response.state == .completed)
    }

    @Test func waitingAndIdleDoNotScheduleWork() async {
        let clock = PresentationClock()
        let response = ModelPromptResponse(scheduler: clock.scheduler)
        let gate = PresentationGate()
        #expect(clock.count == 0)
        let run = Task { await response.run { _ in await gate.pause() } }
        await gate.started()
        #expect(response.state == .waiting)
        clock.advance(by: 10)
        #expect(clock.count == 0)
        response.cancel()
        await run.value
        #expect(response.state == .cancelled)
        response.clear()
        #expect(response.state == .idle)
        #expect(clock.count == 0)
    }

    @Test func scrollFollowsOnlyAtBottomAndNeverDuringSelection() {
        #expect(ModelResponseScrollPolicy.followsAppend(distanceFromBottom: 0, hasSelection: false))
        #expect(ModelResponseScrollPolicy.followsAppend(distanceFromBottom: -10, hasSelection: false))
        #expect(!ModelResponseScrollPolicy.followsAppend(distanceFromBottom: 100, hasSelection: false))
        #expect(!ModelResponseScrollPolicy.followsAppend(distanceFromBottom: 0, hasSelection: true))
        #expect(ModelResponseScrollPolicy.distanceFromBottom(contentHeight: 800, offsetY: 200, viewportHeight: 240) == 360)
    }
}

@MainActor private final class PresentationGate {
    private let began = AsyncStream<Void>.makeStream()
    private let pending = AsyncStream<Void>.makeStream()

    func pause() async {
        began.continuation.yield(())
        for await _ in pending.stream {}
    }
    func started() async {
        var iterator = began.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
    func finish() { pending.continuation.finish(); began.continuation.finish() }
}

@MainActor private final class PresentationClock {
    private final class Entry {
        let deadline: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false
        init(deadline: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.action = action
        }
    }
    private var time: TimeInterval = 0
    private var entries: [Entry] = []
    var count: Int { entries.filter { !$0.cancelled }.count }
    var scheduler: ModelStreamScheduler {
        ModelStreamScheduler(now: { self.time }, schedule: { delay, action in
            let entry = Entry(deadline: self.time + delay, action: action)
            self.entries.append(entry)
            return { entry.cancelled = true }
        })
    }
    func advance(by amount: TimeInterval) {
        time += amount
        let due = entries.filter { !$0.cancelled && $0.deadline <= time + 0.000_000_1 }
        entries.removeAll { entry in due.contains { $0 === entry } }
        due.forEach { $0.action() }
    }
    func fireCancelled() {
        let cancelled = entries.filter(\.cancelled)
        entries.removeAll(where: \.cancelled)
        cancelled.forEach { $0.action() }
    }
}
