import Foundation
import CFNetwork
import NoodleCore

extension Transport {
    func data(_ original: URLRequest, releaseConnection: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var request = original
        let session = beginUse(&request)
        defer { endUse(releaseNow: releaseConnection) }
        let (d, r) = try await session.data(for: request)
        guard let http = r as? HTTPURLResponse else { throw ImageError.io("non-HTTP response") }
        guard d.count <= Self.maxBodyBytes else { throw ImageError.io("registry response is larger than \(Self.maxBodyBytes / (1 << 20)) MiB") }
        return (d, http)
    }

    /// Fetch into `stream.partial` as bytes arrive, so an interrupted transfer keeps what it got.
    func stream(_ original: URLRequest, into stream: BlobStream) async throws -> HTTPURLResponse {
        var request = original
        let session = beginUse(&request)
        defer { endUse() }
        let request2 = request
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HTTPURLResponse, Error>) in
                let task = session.dataTask(with: request2)
                stream.task = task
                lock.lock(); pending[Self.key(session, task)] = Pending(stream: stream, streamCont: cont); lock.unlock()
                if Task.isCancelled { task.cancel() }
                task.resume()
            }
        } onCancel: { stream.cancel() }
    }
    func upload(_ original: URLRequest, file: URL, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> (Data, HTTPURLResponse) {
        var request = original
        let session = beginUse(&request)
        defer { endUse() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
            let task = session.uploadTask(with: request, fromFile: file)
            lock.lock(); pending[Self.key(session, task)] = Pending(uploadCont: cont, progress: progress); lock.unlock()
            task.resume()
        }
    }
}
