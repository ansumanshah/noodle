import Foundation
import Testing
@testable import NoodleCore
@testable import NoodleEngine
@testable import NoodleVM

/// The host treats guest output as data. A compromised workload agent chooses every byte here, so none of it may trap.
@Suite struct HostileGuestTests {
    private func parse(_ s: String) throws -> GuestMessage { try GuestMessage.parse(Data(s.utf8)) }

    @Test func negativeResponseIDIsMalformedNotACrash() {
        #expect(throws: FrameError.self) { try parse(#"{"id":-1,"ok":true}"#) }
        #expect(throws: FrameError.self) { try parse(#"{"id":-1,"ok":false,"error":"x"}"#) }
    }

    @Test func malformedControlFramesThrow() {
        for bad in ["", "[]", "1", "{", #"{"ok":true}"#, #"{"id":"1","ok":true}"#, String(repeating: "[", count: 100_000)] {
            #expect(throws: (any Error).self) { try parse(bad) }
        }
    }

    @Test func extremeEventCodesDoNotTrap() throws {
        guard case .event(.exit(_, let code)) = try parse(#"{"event":"exit","container":"a","code":9223372036854775807}"#) else {
            Issue.record("not an exit event"); return
        }
        #expect(code == -1)
    }

    @Test func unrepresentableCodesAndIDsDoNotTrap() throws {
        guard case .event(.exit(_, let code)) = try parse(#"{"event":"exit","container":"a","code":1e300}"#) else {
            Issue.record("not an exit event"); return
        }
        #expect(code == -1)
        #expect(throws: FrameError.self) { try parse(#"{"id":9223372036854775808,"ok":true}"#) }
    }

    @Test func portBindingsOutsideTheValidRangeAreRefused() throws {
        func check(_ key: String, _ host: String) throws { try Engine.validatePortBindings([key: [PortBinding(HostPort: host)]]) }
        #expect(throws: (any Error).self) { try check("80/tcp", "70000") }
        #expect(throws: (any Error).self) { try check("70000/tcp", "8080") }
        for ok in ["8080", "", "0", "8000-8010"] { try check("80/tcp", ok) }
    }

    @Test func oversizeFramesAreRefusedBeforeBuffering() {
        for trailingBytes in [Data(), Data([0])] {
            var control = ControlFrameDecoder()
            control.append(Data([0xff, 0xff, 0xff, 0xff]) + trailingBytes)
            #expect(throws: FrameError.self) { try control.next() }
        }
        var stream = StreamFrameDecoder()
        stream.append(Data([1, 0xff, 0xff, 0xff, 0xff]))
        #expect(throws: FrameError.self) { try stream.next() }
        var kind = StreamFrameDecoder()
        kind.append(Data([0xee, 0, 0, 0, 0]))
        #expect(throws: FrameError.self) { try kind.next() }
    }

    @Test func tarHeaderWithHostileFieldsDoesNotTrap() {
        var h = Data(repeating: 0, count: 512)
        h.replaceSubrange(0..<1, with: Data("x".utf8))
        for mode in ["-1", "-7777777", "77777777"] {
            var header = h
            header.replaceSubrange(100..<(100 + mode.utf8.count), with: Data(mode.utf8))
            #expect(Engine.pathStat(fromTarHeader: header) != nil)
        }
        var mtime = h
        mtime.replaceSubrange(136..<148, with: Data("777777777777".utf8))
        #expect(Engine.pathStat(fromTarHeader: mtime) != nil)
    }

    @Test func statsArithmeticSaturates() {
        let split = Engine.cpuSplit(UInt64.max)
        #expect(split.user + split.kernel == UInt64.max, "the split must account for every nanosecond at the top of the range")
        #expect(split.user > split.kernel && split.kernel > 0, "user is about 70 percent and kernel the rest, even at the top of the range")
        #expect(Engine.cpuSplit(0) == (0, 0) && Engine.cpuSplit(1) == (0, 1))
        let normal = Engine.cpuSplit(1000)
        #expect(normal.user == 700 && normal.kernel == 300)
        #expect(Engine.saturatingSum(300, [UInt64.max, UInt64.max]) == UInt64.max)
        #expect(Engine.saturatingSum(300, [1, 2]) == 303)
        #expect(Engine.saturatingBytes(.max, .max) == .max)
        #expect(Engine.saturatingBytes(-5, 7) == 7)
        #expect(VMController.balloonTarget(workingSet: UInt64.max) == UInt64.max)
        #expect(VMController.balloonTarget(workingSet: 0) == UInt64(512) << 20)
    }

    /// One VM's agent speaks only for the containers routed to that VM.
    @Test func eventsAreBoundToTheVMThatRunsTheContainer() {
        #expect(Engine.eventAllowed(from: .workload, containerRole: .workload))
        #expect(Engine.eventAllowed(from: .main, containerRole: .main))
        #expect(!Engine.eventAllowed(from: .workload, containerRole: .main))
        #expect(!Engine.eventAllowed(from: .main, containerRole: .workload))
        #expect(!Engine.eventAllowed(from: .workload, containerRole: nil))
    }

    @Test func unconfinedRoutingIsExact() {
        func record(_ opts: [String]) -> ContainerRecord {
            var hc = HostConfig(); hc.SecurityOpt = opts
            return ContainerRecord(id: "a", name: "a", created: Date(), image: "i", imageID: "x", config: ContainerConfig(), hostConfig: hc)
        }
        #expect(Engine.usesWorkload(record(["seccomp=unconfined"])))
        #expect(Engine.usesWorkload(record(["seccomp:unconfined"])))
        #expect(!Engine.usesWorkload(record(["seccomp=unconfined-but-not-really"])))
    }
}
