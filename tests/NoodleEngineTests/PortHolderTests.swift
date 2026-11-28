import Foundation
import Testing
@testable import NoodleEngine

@Suite(.tags(.slow)) struct PortHolderTests {
    @Test func parsesLsofFieldOutputSkippingOwnProcess() {
        let h = NameListener.parseLsof("p4242\ncpython3\n", excluding: 1)
        #expect(h?.pid == "4242" && h?.name == "python3")
        #expect(NameListener.parseLsof("p77\ncnoodled\np4242\ncpython3\n", excluding: 77)?.pid == "4242")
        #expect(NameListener.parseLsof("p77\ncnoodled\n", excluding: 77) == nil)
        #expect(NameListener.parseLsof("", excluding: 1) == nil)
    }

    @Test func namesAnotherProgramHoldingThePort() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", "import socket,time;s=socket.socket();s.bind(('127.0.0.1',0));s.listen(1);"
                       + "print(s.getsockname()[1],flush=True);time.sleep(30)"]
        let out = Pipe(); p.standardOutput = out
        try p.run()
        defer { p.terminate() }
        let port = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = "Bind for 0.0.0.0:\(port) failed: port is already allocated"
        let annotated = await Task.detached { PortConflict.annotate(message) }.value
        #expect(annotated.hasPrefix(message) && annotated.contains("pid \(p.processIdentifier)"))
        #expect(PortConflict.annotate("something else") == "something else")
    }
}
