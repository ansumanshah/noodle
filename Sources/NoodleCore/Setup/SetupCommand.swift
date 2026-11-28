import Foundation

extension SetupPlan {
    /// A Docker context is untrusted shell text, including when it is shown as a later command.
    public static func importCommand(source: String) -> String {
        let quoted = "'" + source.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "noodle import \(quoted) --all"
    }
}
