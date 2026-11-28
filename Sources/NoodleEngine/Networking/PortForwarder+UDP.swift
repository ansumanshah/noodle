import Foundation
import OSLog
import NoodleCore

extension PortListener {
    // MARK: UDP

    func udpReady() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            var ss = sockaddr_storage(); var slen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = buf.withUnsafeMutableBytes { b in
                withUnsafeMutablePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, b.baseAddress, b.count, 0, $0, &slen) } }
            }
            if n < 0 { return }
            let datagram = Data(buf[0..<n])
            let peer = withUnsafeBytes(of: &ss) { Data($0.prefix(Int(slen))) }
            deliver(datagram, from: peer)
        }
    }

    enum UDPAdmission { case existing(UDPSession), open, drop }

    /// Bounded admission: at most `udpMaxSessions` live plus opening peers. A datagram over the limit, or from a peer
    /// whose relay is still opening, is dropped, which UDP allows.
    func udpAdmit(_ peer: Data) -> UDPAdmission {
        lock.lock(); defer { lock.unlock() }
        if let s = udpSessions[peer] { s.lastUsed = Date(); return .existing(s) }
        if stopped || udpOpening.contains(peer) || udpSessions.count + udpOpening.count >= udpMaxSessions { return .drop }
        udpOpening.insert(peer)
        return .open
    }

    func udpOpenFailed(_ peer: Data) { lock.lock(); udpOpening.remove(peer); lock.unlock() }

    /// Installs the opened session and arms the idle timer. False when the listener stopped meanwhile.
    func udpAdopt(_ peer: Data, _ s: UDPSession) -> Bool {
        lock.lock(); defer { lock.unlock() }
        udpOpening.remove(peer)
        if stopped { return false }
        udpSessions[peer] = s
        armUDPExpiryLocked()
        return true
    }

    /// Removes `s` when its relay ended or a write failed.
    func udpDrop(_ peer: Data, _ s: UDPSession) {
        lock.lock()
        if udpSessions[peer] === s { udpSessions[peer] = nil }
        lock.unlock()
        s.stream.close()
    }

    /// One-shot timer, armed only while sessions exist, so an idle listener never wakes.
    private func armUDPExpiryLocked() {
        guard udpTimer == nil, let oldest = udpSessions.values.map(\.lastUsed).min() else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + max(0.05, udpIdle - Date().timeIntervalSince(oldest)))
        t.setEventHandler { [weak self] in self?.udpExpire() }
        udpTimer = t
        t.resume()
    }

    func udpExpire() {
        lock.lock()
        udpTimer?.cancel(); udpTimer = nil
        let now = Date()
        var dead: [UDPSession] = []
        for (k, s) in udpSessions where now.timeIntervalSince(s.lastUsed) >= udpIdle { dead.append(s); udpSessions[k] = nil }
        if !stopped { armUDPExpiryLocked() }
        lock.unlock()
        for s in dead { s.stream.close() }
    }

    private func deliver(_ datagram: Data, from peer: Data) {
        let admission = udpAdmit(peer)
        if case .drop = admission { return }
        let ip = containerIP, port = containerPort, opener = open, listenFD = fd
        track { [self] in
            do {
                let session: UDPSession
                if case .existing(let s) = admission { session = s } else {
                    let stream: GuestStream
                    do { stream = try await opener("relay_udp", ip, port) } catch { udpOpenFailed(peer); throw error }
                    session = UDPSession(stream: stream)
                    guard udpAdopt(peer, session) else { stream.close(); return }
                    track { [self] in
                        var dec = ControlFrameDecoder()
                        do {
                            while let chunk = try await stream.readChunk() {
                                dec.append(chunk)
                                while let pkt = try dec.next() {
                                    touch(session)
                                    peer.withUnsafeBytes { p in
                                        pkt.withUnsafeBytes { b in
                                            _ = sendto(listenFD, b.baseAddress, b.count, 0,
                                                       p.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(p.count))
                                        }
                                    }
                                }
                            }
                        } catch {}
                        udpDrop(peer, session)
                    }
                }
                do { try await session.stream.write(LengthPrefixed.encode(datagram)) } catch { udpDrop(peer, session); throw error }
            } catch {
                log.debug("udp relay failed: \(String(describing: error))")
            }
        }
    }
}
