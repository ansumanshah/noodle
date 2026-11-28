import Foundation
import OSLog
import NoodleCore

public extension Duration {
    public var totalMilliseconds: Int { Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000) }
}
