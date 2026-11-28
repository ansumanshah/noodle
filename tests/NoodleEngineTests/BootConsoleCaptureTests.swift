import Foundation
import Testing
@testable import NoodleVM

struct BootConsoleCaptureTests {
    @Test func wrappedFileKeepsTheLastBytesInOrder() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("console-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try BootConsoleCapture(url: url, queue: DispatchQueue(label: "console-test"))
        let capacity = BootConsoleCapture.capacity
        // Ten chunks of 100 KB: the file wraps several times and must end with the newest capacity bytes.
        var all = Data()
        for i in 0..<10 {
            let chunk = Data(repeating: UInt8(ascii: "a") + UInt8(i), count: 100_000)
            all.append(chunk)
            capture.append(chunk)
            // Open files stay bounded: the tail is trimmed once the file reaches twice the capacity.
            #expect(try Data(contentsOf: url).count <= 2 * capacity)
        }
        capture.close()
        #expect(try Data(contentsOf: url) == all.suffix(capacity))
    }

    @Test func newestBytesAreOnDiskWhileOpen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("console-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = DispatchQueue(label: "console-test")
        let capture = try BootConsoleCapture(url: url, queue: queue)
        queue.sync {
            capture.append(Data(repeating: UInt8(ascii: "a"), count: 300_000))
            capture.append(Data("FINAL-MARKER".utf8))
        }
        #expect(try Data(contentsOf: url).suffix(12) == Data("FINAL-MARKER".utf8))
        queue.sync { capture.close() }
    }
}
