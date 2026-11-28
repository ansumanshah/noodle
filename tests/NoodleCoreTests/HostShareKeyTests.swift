import Testing
@testable import NoodleCore

@Suite struct HostShareKeyTests {
    @Test func keyDependsOnlyOnFolderIdentityAndMode() {
        let a = HostShareKey.key(directory: "/Users/me/app", inode: 7, readOnly: false)
        #expect(a == HostShareKey.key(directory: "/Users/me/app", inode: 7, readOnly: false))
        #expect(a != HostShareKey.key(directory: "/Users/me/app", inode: 7, readOnly: true))
        #expect(a != HostShareKey.key(directory: "/Users/me/app2", inode: 7, readOnly: false))
        #expect(a != HostShareKey.key(directory: "/Users/me/app", inode: 8, readOnly: false))
        #expect(a.count == 26 && a.hasPrefix("k") && a.hasSuffix("w"))
        #expect(a.dropFirst().dropLast().allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func directoryAndFileSourcesShareTheFolderKey() {
        let dir = HostShareKey.guestSource(hostPath: "/Users/me/app", isDirectory: true, readOnly: false)
        let file = HostShareKey.guestSource(hostPath: "/Users/me/app/.env", isDirectory: false, readOnly: false)
        #expect(file == dir + "/.env")
        #expect(HostShareKey.guestSource(hostPath: "/Users/me/app", isDirectory: true, readOnly: true).hasSuffix("r"))
    }
}
