import Foundation
import NoodleCore

/// State of one ranged or full GET that writes straight into a `PartialBlob`. Delegate callbacks for one task arrive
/// serially, so no extra locking is needed here.
final class BlobStream: @unchecked Sendable {
    let partial: PartialBlob
    /// Offset the request asked for with `Range`, or 0 for a plain GET.
    let requestedOffset: Int64
    private let expectedSize: Int64?
    private let progress: (@Sendable (Int64, Int64) -> Void)?
    var task: URLSessionTask?
    var response: HTTPURLResponse?
    var errorBody = Data()
    var failure: Error?
    /// We cancelled the task on purpose (a 206 that does not start where we asked).
    var stopped = false
    var restartNeeded = false
    /// The server honoured `Range`: this attempt appended to existing bytes.
    var resumed = false
    private var total: Int64 = 0

    init(partial: PartialBlob, expectedSize: Int64?, progress: (@Sendable (Int64, Int64) -> Void)?) {
        self.partial = partial; self.requestedOffset = partial.size
        self.expectedSize = expectedSize; self.progress = progress
    }

    func cancel() { task?.cancel() }

    private var carriesBody: Bool { response.map { $0.statusCode == 200 || $0.statusCode == 206 } ?? false }

    /// Decide what to do with the response headers. False cancels the transfer.
    func accept(_ r: HTTPURLResponse) -> Bool {
        response = r
        switch r.statusCode {
        case 200:
            // A server that ignores Range sends the whole blob: start over.
            if partial.size > 0 { do { try partial.reset() } catch { failure = error; return false } }
            total = expectedSize ?? max(r.expectedContentLength, 0)
            return true
        case 206:
            guard requestedOffset > 0, Self.rangeStart(r) == requestedOffset, partial.size == requestedOffset else {
                restartNeeded = true; stopped = true; return false
            }
            resumed = true
            total = expectedSize ?? (r.expectedContentLength > 0 ? requestedOffset + r.expectedContentLength : 0)
            return true
        default:
            return true
        }
    }

    func receive(_ data: Data) {
        guard carriesBody else {
            if errorBody.count < 4096 { errorBody.append(data.prefix(4096 - errorBody.count)) }
            return
        }
        if let expectedSize, partial.size + Int64(data.count) > expectedSize {
            failure = ImageError.io("registry sent more than the \(expectedSize) bytes expected for this blob"); task?.cancel(); return
        }
        do { try partial.append(data) } catch { failure = error; task?.cancel(); return }
        progress?(partial.size, total)
    }

    /// Start byte of `Content-Range: bytes START-END/TOTAL`.
    static func rangeStart(_ r: HTTPURLResponse) -> Int64? {
        guard let h = r.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let parts = h.split(separator: " ")
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        return parts[1].split(separator: "-").first.flatMap { Int64($0) }
    }
}
