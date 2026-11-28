import Foundation
import CFNetwork
import NoodleCore

extension Transport {
    /// Largest manifest, token or upload-reply body kept in memory.
    static let maxBodyBytes = 16 << 20

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); let s = pending[Self.key(session, dataTask)]?.stream; lock.unlock()
        guard let s, let http = response as? HTTPURLResponse else { completionHandler(.allow); return }
        completionHandler(s.accept(http) ? .allow : .cancel)
    }
    // download finished: the temp file is deleted when this returns, so move it now
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = tempDirectory.appendingPathComponent("dl-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: location, to: dest)
        lock.lock(); pending[Self.key(session, downloadTask)]?.movedTo = dest; lock.unlock()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); let p = pending[Self.key(session, downloadTask)]?.progress; lock.unlock()
        p?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock(); let p = pending[Self.key(session, task)]?.progress; lock.unlock()
        p?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let key = Self.key(session, dataTask)
        let s = pending[key]?.stream
        var tooBig = false
        if s == nil, var p = pending[key] {
            if p.body.count + data.count > Self.maxBodyBytes { p.overflow = true; p.body = Data(); tooBig = true }
            else { p.body.append(data) }
            pending[key] = p
        }
        lock.unlock()
        if tooBig { dataTask.cancel() }
        s?.receive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let p = pending.removeValue(forKey: Self.key(session, task)); lock.unlock()
        guard let p else { return }
        if p.overflow {
            let e = ImageError.io("registry response is larger than \(Self.maxBodyBytes / (1 << 20)) MiB")
            p.cont?.resume(throwing: e); p.uploadCont?.resume(throwing: e); return
        }
        if let s = p.stream, let c = p.streamCont {
            if let failure = s.failure { c.resume(throwing: failure) }
            else if let r = s.response, error == nil || s.stopped { c.resume(returning: r) }
            else { c.resume(throwing: error ?? ImageError.io("no HTTP response")) }
            return
        }
        if let error {
            if let f = p.movedTo { try? FileManager.default.removeItem(at: f) }
            p.cont?.resume(throwing: error); p.uploadCont?.resume(throwing: error); return
        }
        guard let http = task.response as? HTTPURLResponse else {
            let e = ImageError.io("no HTTP response")
            p.cont?.resume(throwing: e); p.uploadCont?.resume(throwing: e); return
        }
        if let c = p.cont {
            if let f = p.movedTo { c.resume(returning: (f, http)) } else { c.resume(throwing: ImageError.io("download produced no file")) }
        }
        p.uploadCont?.resume(returning: (p.body, http))
    }

    /// Answers a proxy's 407 with the stored proxy credentials. Other challenges use default handling.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        lock.lock(); let e = proxy.endpoint; lock.unlock()
        guard challenge.protectionSpace.isProxy(), challenge.previousFailureCount == 0, let user = e?.user, let pass = e?.password else {
            completionHandler(.performDefaultHandling, nil); return
        }
        completionHandler(.useCredential, URLCredential(user: user, password: pass, persistence: .none))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        // A redirect can switch to a direct route. Never carry explicit proxy credentials there.
        next.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        if let old = task.originalRequest?.url, let new = request.url,
           old.scheme != new.scheme || old.host != new.host || old.port != new.port {
            if new.scheme?.lowercased() != "https" || task.originalRequest?.httpBody != nil || task.originalRequest?.httpBodyStream != nil ||
               !["GET", "HEAD"].contains(task.originalRequest?.httpMethod ?? "GET") {
                completionHandler(nil); return
            }
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }
}
