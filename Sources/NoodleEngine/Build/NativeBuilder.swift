import Foundation
import NoodleCore

/// A single host helper and its connected guest worker. Neither outlives the last client.
final class NativeBuilder: @unchecked Sendable {
    let process: Process
    let stream: GuestStream
    let directory: URL
    let exit = AsyncStream<Void>.makeStream()
    let generation: UUID
    let token = UUID().uuidString
    let socketPath: String
    // Engine actor only. Released with this transient builder.
    var buildHistoryRecords: [String: BuildHistoryRecord] = [:]

    init(process: Process, stream: GuestStream, directory: URL, socketPath: String, generation: UUID) {
        self.generation = generation
        self.process = process; self.stream = stream; self.directory = directory; self.socketPath = socketPath
        let finished = exit.continuation
        process.terminationHandler = { _ in finished.finish() }
    }

    func stop() {
        stream.close()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }

    @concurrent func connect() async throws -> GuestStream {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            let e = errno; Darwin.close(fd); throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        return GuestStream(channel: FDChannel(fd: fd), leftover: Data())
    }
}
