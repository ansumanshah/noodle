import Darwin
import Foundation
import Network
import Security

extension TLSSession {
    // MARK: - Encrypted socket relay

    func pump(local: Int32, wake: Int32, prefix: Data, deadline: DispatchTime) {
        var toLocal = prefix, toClient = Data()
        var clientEOF = false, localEOF = false, localShut = false
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let state = queue.sync { (ready, failed) }
            if state.1 { return }
            if !state.0, DispatchTime.now() >= deadline { return }
            if !toLocal.isEmpty {
                let n = toLocal.withUnsafeBytes { Darwin.write(local, $0.baseAddress, $0.count) }
                if n > 0 { toLocal.removeFirst(n) } else if n < 0, errno != EAGAIN, errno != EINTR { return }
            }
            if !toClient.isEmpty {
                let n = toClient.withUnsafeBytes { Darwin.write(tls, $0.baseAddress, $0.count) }
                if n > 0 { toClient.removeFirst(n) } else if n < 0, errno != EAGAIN, errno != EINTR { return }
            }
            if clientEOF, toLocal.isEmpty, !localShut { shutdown(local, SHUT_WR); localShut = true }
            if localEOF, toClient.isEmpty { return }
            var fds = [pollfd(fd: tls, events: 0, revents: 0), pollfd(fd: local, events: 0, revents: 0), pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
            if !clientEOF, toLocal.count < Self.cap { fds[0].events |= Int16(POLLIN) }
            if !toClient.isEmpty { fds[0].events |= Int16(POLLOUT) }
            if !localEOF, toClient.count < Self.cap { fds[1].events |= Int16(POLLIN) }
            if !toLocal.isEmpty { fds[1].events |= Int16(POLLOUT) }
            // An EOF descriptor with no requested events must not spin on POLLHUP.
            for index in 0...1 where fds[index].events == 0 { fds[index].fd = -1 }
            let now = DispatchTime.now()
            if !state.0, now >= deadline { return }
            let timeout: Int32 = state.0 ? -1 : Int32(min((deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000 + 1, UInt64(Int32.max)))
            let count = poll(&fds, 3, timeout)
            if count < 0 { if errno == EINTR { continue }; return }
            if count == 0 { return }
            if fds[2].revents != 0 { while Darwin.read(wake, &scratch, scratch.count) > 0 {} }
            if fds.contains(where: { $0.revents & Int16(POLLERR | POLLNVAL) != 0 }) { return }
            for index in 0...1 where fds[index].revents & Int16(POLLIN | POLLHUP) != 0 {
                if index == 0, (clientEOF || toLocal.count >= Self.cap) { continue }
                if index == 1, (localEOF || toClient.count >= Self.cap) { continue }
                let n = Darwin.read(fds[index].fd, &scratch, scratch.count)
                if n > 0 {
                    if index == 0 { toLocal.append(contentsOf: scratch.prefix(n)) } else { toClient.append(contentsOf: scratch.prefix(n)) }
                } else if n == 0 {
                    if index == 0 { clientEOF = true } else { localEOF = true }
                } else if errno != EAGAIN, errno != EINTR { return }
            }
        }
    }
}
