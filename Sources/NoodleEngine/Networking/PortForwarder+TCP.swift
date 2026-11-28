import Foundation
import OSLog
import NoodleCore

extension PortListener {
    // MARK: TCP

    func acceptReady() {
        while true {
            var ss = sockaddr_storage(); var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let c = withUnsafeMutablePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) } }
            if c < 0 { return }
            if isRefusing { Darwin.close(c); continue }
            let client = FDChannel(fd: c, label: "app.noodle.port.client")
            let ip = containerIP, port = containerPort, opener = open
            track {
                do {
                    let stream = try await opener("relay_tcp", ip, port)
                    await Self.bridge(client, stream)
                } catch {
                    client.close()
                }
            }
        }
    }

    /// Pump bytes both ways until both directions finish.
    static func bridge(_ client: FDChannel, _ stream: GuestStream) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    while let d = try await client.read() { try await stream.write(d) }
                } catch {}
                stream.finishWriting()
            }
            group.addTask {
                do {
                    while let d = try await stream.readChunk() { try await client.write(d) }
                } catch {}
                client.shutdownWrite()
            }
            await group.waitForAll()
        }
        client.close()
        stream.close()
    }
}
