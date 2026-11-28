import Testing
@testable import NoodleCore

@Suite struct HostShareTableTests {
    private func table() -> HostShareTable {
        var t = HostShareTable()
        t.add(["ka": .init(path: "/a", readOnly: false, inode: 1), "kb": .init(path: "/b", readOnly: true, inode: 2)])
        return t
    }

    @Test func liveFoldersResolveToThemselves() {
        #expect(table().resolved(placeholder: "/empty") { $0 == "/a" ? 1 : 2 } == table().entries)
    }

    @Test func aMissingFolderKeepsItsKeyAndModeOnThePlaceholder() {
        let live = table().resolved(placeholder: "/empty") { $0 == "/a" ? 1 : nil }
        #expect(live["ka"]?.path == "/a")
        #expect(live["kb"] == .init(path: "/empty", readOnly: true, inode: 2))
    }

    @Test func aFolderRecreatedAtTheSamePathStaysOnThePlaceholder() {
        #expect(table().resolved(placeholder: "/empty") { $0 == "/a" ? 99 : 2 }["ka"]?.path == "/empty")
    }

    @Test func addingNeverReplacesARetainedKey() {
        var t = table()
        t.add(["ka": .init(path: "/other", readOnly: true, inode: 3)])
        #expect(t.entries["ka"] == .init(path: "/a", readOnly: false, inode: 1))
    }
}
