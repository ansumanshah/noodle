import Foundation
import Testing
@testable import NoodleCore

@Suite struct PrivateFileTests {
    @Test func writesOwnerOnlyFileInOwnerOnlyFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-pf-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sub/key")
        try PrivateFile.write(Data("a".utf8), to: file)
        try PrivateFile.write(Data("b".utf8), to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "b")
        func mode(_ u: URL) throws -> Int { try (FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int ?? 0) & 0o777 }
        #expect(try mode(file) == 0o600)
        #expect(try mode(dir.appendingPathComponent("sub")) == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("sub").path) == ["key"])
    }
}
