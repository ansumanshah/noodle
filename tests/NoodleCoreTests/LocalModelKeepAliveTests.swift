import Foundation
import Testing
@testable import NoodleCore

@Suite struct LocalModelKeepAliveTests {
    @Test(arguments: zip(["5m", "1h", "0", "300", "1h30m", "1.5m", ".5s", "250ms", "1s500ms", "2us", "2µs", "+5m", "-0"],
                         [300.0, 3600, 0, 300, 5400, 90, 0.5, 0.25, 1.5, 0.000002, 0.000002, 300, 0]))
    func durations(text: String, seconds: Double) throws {
        #expect(try LocalModelKeepAlive(text).seconds == seconds)
    }

    @Test(arguments: ["-1", "-5m", "-0.5s"])
    func negativeMeansNever(_ text: String) throws {
        #expect(try LocalModelKeepAlive(text).seconds == nil)
        #expect(try LocalModelKeepAlive(text).idleEvictSeconds() == nil)
    }

    @Test(arguments: ["", " ", "5 m", "5M", "1d", "1.5", "NaN", "inf", "1e3s", "--1", "1..2s", "s", "-", "999999999999999999999h"])
    func rejectsInvalidDurations(_ text: String) {
        #expect(throws: CocoaError.self) { try LocalModelKeepAlive(text) }
    }

    @Test func defaultAndCodable() throws {
        #expect(LocalModelKeepAlive.default.seconds == 300)
        for text in ["5m", "0", "-1"] {
            let policy = try LocalModelKeepAlive(text)
            #expect(try JSONDecoder().decode(LocalModelKeepAlive.self, from: JSONEncoder().encode(policy)) == policy)
        }
    }

    @Test(arguments: zip(["5m", "1h", "0", "-0", "1ns", "250ms", "1.001s", "2s", "2147483648s", "4294967295s"],
                         [300, 3600, 1, 1, 1, 1, 2, 2, 2_147_483_648, UInt32.max]))
    func mapsToIdleEvictionSeconds(text: String, seconds: UInt32) throws {
        #expect(try LocalModelKeepAlive(text).idleEvictSeconds() == seconds)
        #expect(try LocalModelKeepAlive.default.idleEvictSeconds() == 300)
    }

    @Test(arguments: ["4294967295.1s", "4294967296s"])
    func rejectsDurationsBeyondTheNativeIntegerLimit(_ text: String) throws {
        let duration = try LocalModelKeepAlive(text)
        #expect(throws: CocoaError.self) { try duration.idleEvictSeconds() }
    }

    @Test func mlxBackendUsesItsRuntimeIndependentName() throws {
        struct Holder: Codable { let backend: LocalModelBackend }
        let holder = try JSONDecoder().decode(Holder.self, from: Data(#"{"backend":"mlx"}"#.utf8))
        #expect(holder.backend == .mlx)
        #expect(String(decoding: try JSONEncoder().encode(Holder(backend: .mlx)), as: UTF8.self) == #"{"backend":"mlx"}"#)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Holder.self, from: Data(#"{"backend":"other"}"#.utf8)) }
    }
}
