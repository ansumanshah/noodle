import Foundation
import NoodleCore

func selfDirectory() -> String {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    _NSGetExecutablePath(&buf, &size)
    return URL(fileURLWithPath: String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath().deletingLastPathComponent().path
}

func noodledPath() -> String {
    let sibling = selfDirectory() + "/noodled"
    if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
    let bundled = URL(fileURLWithPath: selfDirectory()).deletingLastPathComponent().appendingPathComponent("MacOS/noodled").path
    if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
    return which("noodled") ?? sibling
}
