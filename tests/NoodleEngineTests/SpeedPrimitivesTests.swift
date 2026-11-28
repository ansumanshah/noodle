import Foundation
import Testing
@testable import NoodleCore
@testable import NoodleVM

@Suite struct SpeedPrimitivesTests {
    @Test func fileDigestMatchesDataDigest() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-digest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data((0..<(3 << 20) + 17).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: url)
        #expect(try Digest.sha256(file: url) == Digest.sha256(data))
        try Data().write(to: url)
        #expect(try Digest.sha256(file: url) == Digest.sha256(Data()))
    }

    @Test func reusableTimerFiresOnceAndCanBeMovedOrDisarmed() async throws {
        let count = Counter()
        let timer = ReusableTimer { count.bump() }
        #expect(!timer.isArmed)
        timer.arm(after: .seconds(30), leeway: .milliseconds(1))
        timer.arm(after: .milliseconds(20), leeway: .milliseconds(1))   // moved earlier
        // Background QoS can delay a timer by seconds, so wait for the firing instead of sleeping a fixed time.
        try await waitUntil { count.value > 0 }
        try await Task.sleep(for: .milliseconds(100))   // a second firing would show up here
        #expect(count.value == 1)
        #expect(!timer.isArmed)
        timer.arm(after: .milliseconds(20), leeway: .milliseconds(1))
        timer.disarm()
        try await Task.sleep(for: .milliseconds(200))
        #expect(count.value == 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
