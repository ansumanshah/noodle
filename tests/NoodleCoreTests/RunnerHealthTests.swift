import Foundation
import Testing
@testable import NoodleCore

private let gb = RunnerHealth.gigabyte

@Suite struct RunnerHealthTests {
    @Test func belowThresholdHolds() {
        let hold = RunnerHealth.decide(freeBytes: 6 * gb, pressure: .normal, previous: nil)
        #expect(hold == .disk(freeBytes: 6 * gb, needsBytes: 10 * gb))
        #expect(hold?.text == "Holding new jobs: 6 GB free on the Noodle volume, needs 10 GB")
    }

    @Test func boundaryTakesAtExactlyThreshold() {
        #expect(RunnerHealth.decide(freeBytes: 10 * gb, pressure: .normal, previous: nil) == nil)
        #expect(RunnerHealth.decide(freeBytes: 10 * gb - 1, pressure: .normal, previous: nil) != nil)
    }

    @Test func hysteresisOnRecovery() {
        let held = RunnerHold.disk(freeBytes: 6 * gb, needsBytes: 10 * gb)
        #expect(RunnerHealth.decide(freeBytes: 12 * gb, pressure: .normal, previous: held) != nil)
        #expect(RunnerHealth.decide(freeBytes: 15 * gb - 1, pressure: .normal, previous: held) != nil)
        #expect(RunnerHealth.decide(freeBytes: 15 * gb, pressure: .normal, previous: held) == nil)
        // Not held before: 12 GB is fine.
        #expect(RunnerHealth.decide(freeBytes: 12 * gb, pressure: .normal, previous: nil) == nil)
    }

    @Test func criticalMemoryPressureAloneHolds() {
        #expect(RunnerHealth.decide(freeBytes: 500 * gb, pressure: .critical, previous: nil) == .memory(.critical))
        #expect(RunnerHealth.decide(freeBytes: 500 * gb, pressure: .warning, previous: nil) == nil)
        #expect(RunnerHealth.decide(freeBytes: 500 * gb, pressure: .warning, previous: .memory(.critical)) == nil)
        #expect(RunnerHealth.decide(freeBytes: 500 * gb, pressure: .normal, previous: .memory(.critical)) == nil)
    }

    @Test func aHoldAloneChangesThePublishedState() {
        let state = RunnerState()
        let held = state.publishing(message: nil, running: [], runningRepos: [], awake: false, hold: "Holding new jobs: low")
        #expect(held != state && held.hold == "Holding new jobs: low")
        let recovered = held.publishing(message: nil, running: [], runningRepos: [], awake: false, hold: nil)
        #expect(recovered != held && recovered.hold == nil)
    }

    @Test func memoryHoldDoesNotRaiseTheDiskBar() {
        #expect(RunnerHealth.decide(freeBytes: 12 * gb, pressure: .normal, previous: .memory(.critical)) == nil)
    }

    @Test func diskHoldSurvivesAMemoryHold() {
        let held = RunnerHealth.decide(freeBytes: 9 * gb, pressure: .normal, previous: nil)
        let during = RunnerHealth.decide(freeBytes: 12 * gb, pressure: .critical, previous: held)
        #expect(during != nil)
        #expect(RunnerHealth.decide(freeBytes: 12 * gb, pressure: .normal, previous: during) != nil)
        #expect(RunnerHealth.decide(freeBytes: 15 * gb, pressure: .normal, previous: during) == nil)
    }

    @Test func unreadableDiskDoesNotHold() {
        #expect(RunnerHealth.decide(freeBytes: nil, pressure: .normal, previous: nil) == nil)
    }

    @Test func freeBytesWalksUpToAFolderThatExists() {
        let missing = NSTemporaryDirectory() + "noodle-missing-\(UUID().uuidString)/a/b"
        let free = RunnerHealth.freeBytes(near: missing)
        #expect(free != nil && free! > 0)
        #expect(RunnerHealth.freeBytes(near: missing) != nil)
    }
}
