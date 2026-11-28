import Foundation
import Testing
@testable import NoodleEngine

@Suite struct UDPSessionLimitTests {
    private func session() -> (PortListener.UDPSession, Int32) {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (PortListener.UDPSession(stream: GuestStream(channel: FDChannel(fd: fds[0]), leftover: Data())), fds[1])
    }

    private func state(_ l: PortListener) -> (Int, Bool) { l.lock.lock(); defer { l.lock.unlock() }; return (l.udpSessions.count, l.udpTimer != nil) }

    @Test func admissionIsCappedAndIdleSessionsExpireWithoutTraffic() async throws {
        let l = try PortListener(proto: "udp", hostIP: "127.0.0.1", hostPort: 0, containerIP: "10.0.0.2", containerPort: 53) { _, _, _ in throw EngineError.invalid("unused") }
        defer { l.stop() }
        l.udpMaxSessions = 2; l.udpIdle = 0.2
        var peers: [UInt8] = [1, 2, 3]
        var others: [Int32] = []
        defer { others.forEach { close($0) } }
        for p in peers.prefix(2) {
            guard case .open = l.udpAdmit(Data([p])) else { Issue.record("expected open"); return }
            let (s, other) = session(); others.append(other)
            #expect(l.udpAdopt(Data([p]), s))
        }
        guard case .drop = l.udpAdmit(Data([peers.removeLast()])) else { Issue.record("third peer must be dropped"); return }
        // No further datagram arrives: the timer alone must remove both sessions.
        try await waitUntil { state(l).0 == 0 }
        try await Task.sleep(nanoseconds: 300_000_000)
        let (left, armed) = state(l)
        #expect(left == 0)
        #expect(!armed)
        guard case .open = l.udpAdmit(Data([9])) else { Issue.record("slot should be free again"); return }
    }
}
