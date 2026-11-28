import Foundation
import Testing
@testable import NoodleApp

@Suite struct ImageFilesTests {
    @Test func rootListingKeepsHiddenFilesAndDirectoryPaths() {
        let entries = DockerAPI.parseListing(".hidden\nbin/\netc/\nfile\n", path: "/")
        #expect(entries.map(\.path) == ["/bin", "/etc", "/.hidden", "/file"])
        #expect(entries.prefix(2).allSatisfy { $0.isDirectory })
        #expect(DockerAPI.parseListing("", path: "/tmp").isEmpty)
    }

    @Test func historyDecodesDockerResponsesAndEmptyHistory() throws {
        let data = Data(#"[{"Id":"sha256:abc","Created":42,"CreatedBy":"RUN echo hi","Size":123}]"#.utf8)
        let history = try JSONDecoder().decode([ImageHistory].self, from: data)
        #expect(history.first?.createdBy == "RUN echo hi")
        #expect(history.first?.size == 123)
        #expect(try JSONDecoder().decode([ImageHistory].self, from: Data("[]".utf8)).isEmpty)
    }
}

@Suite struct FileSaveSafetyTests {
    @Test func listingDropsNamesThatEscape() {
        let entries = DockerAPI.parseListing("../evil\na/b\n..\nok\n", path: "/tmp")
        #expect(entries.map(\.name) == ["ok"])
    }

    @Test func tarHonoursPaxSizeAndFlagsTruncatedBodies() {
        func block(_ s: String, _ size: Int, _ type: Unicode.Scalar) -> Data {
            var h = Data(count: 512)
            h.replaceSubrange(0..<min(s.utf8.count, 100), with: Array(s.utf8.prefix(100)))
            h.replaceSubrange(124..<135, with: Array(String(format: "%011o", size).utf8))
            h[156] = UInt8(ascii: type)
            return h
        }
        let rec = "20 size=8589934592\n"
        var tar = block("pax", rec.utf8.count, "x") + Data(rec.utf8) + Data(count: 512 - rec.utf8.count)
        tar += block("big", 0, "0") + Data(count: 512)
        let e = Tar.entries(tar)
        #expect(e.count == 1 && e[0].size == 8_589_934_592 && !e[0].complete)
    }
}
