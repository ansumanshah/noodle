import Foundation
import Testing
@testable import NoodleApp

@Suite struct FilesQuarantineTests {
    @Test func savedFileCarriesTheQuarantineFlag() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-quarantine-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try FilesModel.quarantine(file)
        let size = getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0)
        #expect(size > 0)
        var buffer = [UInt8](repeating: 0, count: max(size, 0))
        _ = getxattr(file.path, "com.apple.quarantine", &buffer, buffer.count, 0, 0)
        // "flags;time;agent;uuid". The agent field stays empty in the bundle-less test runner, so check the flags.
        let flags = String(decoding: buffer, as: UTF8.self).split(separator: ";").first.flatMap { UInt32($0, radix: 16) }
        #expect((flags ?? 0) != 0)
    }
}
