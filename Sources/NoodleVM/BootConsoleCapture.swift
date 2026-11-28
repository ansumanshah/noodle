import Foundation
import Virtualization
import NoodleCore
import os

/// Event-driven capture; all operations run on the VM queue. Bytes go straight to disk with no memory
/// mirror: the file grows to twice `capacity`, then keeps its newest `capacity` bytes, so it is always
/// chronological and ordinary tail/cat tools can read it.
final class BootConsoleCapture: @unchecked Sendable {
    static let capacity = 256 * 1024
    private let pipe = Pipe()
    private let file: FileHandle
    private var source: DispatchSourceRead?
    private var size: UInt64 = 0
    private var reachedEOF = false
    private let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 16 * 1024, alignment: 1)
    var writer: FileHandle { pipe.fileHandleForWriting }

    init(url: URL, queue: DispatchQueue) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw VMError.startFailed("cannot create boot console at \(url.path)")
            }
        }
        file = try FileHandle(forUpdating: url)
        size = try file.seekToEnd()
        try keepTail()
        let reader = pipe.fileHandleForReading
        let fd = reader.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
            throw VMError.startFailed("cannot configure boot console pipe")
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { try? reader.close() }
        self.source = source
        source.resume()
    }

    func appendDiagnostic(_ data: Data) {
        drain()
        append(data)
    }

    func append(_ data: some DataProtocol) {
        do {
            try file.write(contentsOf: data)
            size += UInt64(data.count)
            if size > 2 * UInt64(Self.capacity) { try keepTail() }
        } catch {
            Logger(subsystem: "app.noodle", category: "vm").error("boot console write failed: \(error, privacy: .public)")
        }
    }

    /// Move the newest `capacity` bytes to the start of the file and leave the handle at its end.
    private func keepTail() throws {
        guard size > UInt64(Self.capacity) else { return }
        try file.seek(toOffset: size - UInt64(Self.capacity))
        let tail = try file.read(upToCount: Self.capacity) ?? Data()
        try file.seek(toOffset: 0)
        try file.write(contentsOf: tail)
        try file.truncate(atOffset: UInt64(tail.count))
        size = try file.seekToEnd()
    }

    private func drain() {
        guard !reachedEOF else { return }
        while true {
            let count = read(pipe.fileHandleForReading.fileDescriptor, buffer.baseAddress, buffer.count)
            if count > 0 { append(UnsafeRawBufferPointer(rebasing: buffer[..<count])) }
            else if count < 0 && errno == EINTR { continue }
            else {
                if count == 0 {
                    reachedEOF = true
                    source?.cancel()
                }
                break
            }
        }
    }

    func close() {
        guard let source else { return }
        drain()
        do { try keepTail() } catch {
            Logger(subsystem: "app.noodle", category: "vm").error("boot console trim failed: \(error, privacy: .public)")
        }
        source.cancel()
        self.source = nil
        try? writer.close()
        try? file.close()
    }

    deinit {
        close()
        buffer.deallocate()
    }
}
