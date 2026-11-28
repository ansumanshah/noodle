import Darwin
import Foundation
import Network
import Security

extension TLSSession {
    /// Queue-confined plain socket adapter. One 64 KB receive and send at a time propagate socket backpressure to TLS.
    final class PlaintextRelay: @unchecked Sendable {
        private let fd: Int32
        private let connection: NWConnection
        private let reader: DispatchSourceRead
        private let writer: DispatchSourceWrite
        private var readerSuspended = true, writerSuspended = true, stopped = false
        private var pending = Data()
        private var receivedEOF = false

        private final class Closer: @unchecked Sendable {
            let fd: Int32
            var remaining = 2 // Both source cancellation handlers execute on the same serial queue.
            init(_ fd: Int32) { self.fd = fd }
            func close() { remaining -= 1; if remaining == 0 { Darwin.close(fd) } }
        }

        init(fd: Int32, connection: NWConnection, queue: DispatchQueue) {
            self.fd = fd; self.connection = connection
            reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            let closer = Closer(fd)
            reader.setCancelHandler { closer.close() }; writer.setCancelHandler { closer.close() }
            reader.setEventHandler { [weak self] in self?.readPlain() }
            writer.setEventHandler { [weak self] in self?.writePlain() }
        }

        func start() { readerSuspended = false; reader.resume(); receive() }
        func stop() {
            guard !stopped else { return }
            stopped = true
            if readerSuspended { reader.resume(); readerSuspended = false }
            if writerSuspended { writer.resume(); writerSuspended = false }
            reader.cancel(); writer.cancel()
        }

        private func readPlain() {
            guard !stopped else { return }
            reader.suspend(); readerSuspended = true
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                connection.send(content: Data(bytes.prefix(count)), completion: .contentProcessed { [weak self] error in
                    guard let self, !self.stopped else { return }
                    if error != nil { self.connection.cancel(); return }
                    self.readerSuspended = false; self.reader.resume()
                })
            } else if count == 0 {
                // finalMessage write-closes after queued records. Cancelling on successful processing could
                // discard records still enqueued in the stack; the encrypted relay drains them before teardown.
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.connection.cancel() }
                })
            } else if errno == EAGAIN || errno == EINTR {
                readerSuspended = false; reader.resume()
            } else { connection.cancel() }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
                guard let self, !self.stopped else { return }
                if error != nil { self.connection.cancel(); return }
                self.pending = data ?? Data(); self.receivedEOF = complete; self.writePlain()
            }
        }

        private func writePlain() {
            guard !stopped else { return }
            if !pending.isEmpty {
                let count = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if count > 0 { pending.removeFirst(count) }
                else if count < 0, errno != EAGAIN, errno != EINTR { connection.cancel(); return }
            }
            if !pending.isEmpty {
                if writerSuspended { writerSuspended = false; writer.resume() }
            } else {
                if !writerSuspended { writer.suspend(); writerSuspended = true }
                if receivedEOF { shutdown(fd, SHUT_WR) } else { receive() }
            }
        }
    }
}
