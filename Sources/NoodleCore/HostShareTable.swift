/// Folders registered with a VM since it booted, keyed by `HostShareKey`.
///
/// A key is never withdrawn while the VM runs: the guest kernel keeps cached inodes for that name and a
/// re-registered share hangs or fails lookups. A folder deleted on the Mac cannot keep its path either, because every
/// later share update would hand the dead path to Virtualization.framework and hang the next bind. So a folder that
/// is gone, or replaced by another inode, keeps its key on an empty placeholder. Its replacement has a new key.
public struct HostShareTable: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var path: String
        public var readOnly: Bool
        public var inode: UInt64
        public init(path: String, readOnly: Bool, inode: UInt64) { self.path = path; self.readOnly = readOnly; self.inode = inode }
    }

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    public mutating func add(_ new: [String: Entry]) { entries.merge(new) { old, _ in old } }

    public mutating func removeAll() { entries.removeAll() }

    public func resolved(placeholder: String, inodeOf: (String) -> UInt64?) -> [String: Entry] {
        entries.mapValues { inodeOf($0.path) == $0.inode ? $0 : Entry(path: placeholder, readOnly: $0.readOnly, inode: $0.inode) }
    }
}
