import Foundation

struct FileEntry: Identifiable, Hashable, Sendable {
    var path: String
    var name: String
    var isDirectory: Bool
    var id: String { path }
}
