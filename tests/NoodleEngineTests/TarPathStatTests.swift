import Foundation
import Testing
@testable import NoodleEngine

/// `docker cp` decides file or directory from this stat, so it must describe the real entry.
@Suite struct TarPathStatTests {
    private func block(name: String, size: Int = 0, mode: Int = 0o755, type: Character) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, _ at: Int) { b.replaceSubrange(at..<(at + text.utf8.count), with: Array(text.utf8)) }
        put(name, 0)
        put(String(format: "%07o", mode), 100)
        put(String(format: "%011o", size), 124)
        put(String(format: "%011o", 1_700_000_000), 136)
        b[156] = type.asciiValue ?? 0
        return b
    }

    private func pax(_ text: String) -> [UInt8] {
        let body = Array(text.utf8)
        return block(name: "PaxHeader", size: body.count, mode: 0o644, type: "x") + body
            + [UInt8](repeating: 0, count: (512 - body.count % 512) % 512)
    }

    @Test func directoryBehindPAXHeaderIsADirectory() throws {
        let tar = pax("20 path=dest/inner/\n") + block(name: "dest/", type: "5")
        let stat = try #require(Engine.pathStat(fromTarHeader: Data(tar)))
        #expect(stat.mode & 0x8000_0000 != 0)
        #expect(stat.name == "inner")
    }

    @Test func prefixWithoutTheRealEntryIsNotAStat() {
        let header = pax("20 path=dest/inner/\n")
        #expect(Engine.pathStat(fromTarHeader: Data(header)) == nil)
        #expect(Engine.pathStat(fromTarHeader: Data(header.prefix(512))) == nil)
    }

    @Test func symlinkAndSizeComeFromPAX() throws {
        let tar = pax("16 linkpath=abc\n") + pax("12 size=123\n") + block(name: "lnk", type: "2")
        let stat = try #require(Engine.pathStat(fromTarHeader: Data(tar)))
        #expect(stat.mode & 0x0800_0000 != 0)
        #expect(stat.linkTarget == "abc")
        #expect(stat.size == 123)
    }

    @Test func hostileRecordsEndWithoutACrash() {
        for hostile in ["999999999 path=x\n", "1 x", "-5 a=b\n", " =\n", "5"] {
            _ = Engine.parsePAX(Array(hostile.utf8))
        }
        #expect(Engine.pathStat(fromTarHeader: Data(block(name: "x", size: Int(Engine.maxTarStatPrefix) + 1, type: "x"))) == nil)
    }
}
