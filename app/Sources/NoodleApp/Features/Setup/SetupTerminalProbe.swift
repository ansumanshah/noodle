import Foundation
import NoodleCore

extension SetupProbe {
    /// Ask a fresh interactive login shell what it will run after all startup files have applied.
    /// The bounded runner stops the whole process group if a preserved command hangs.
    static func terminalFacts(home: String, shell: String) async -> (applied: Bool, conflict: String?) {
        let script = #"printf '\nNOODLE_SETUP_PATH:%s\n' "$PATH"; printf 'NOODLE_SETUP_DOCKER:'; command -v docker; printf 'NOODLE_SETUP_VERSION:\n'; docker --version"#
        let result = await CLI.run(executable: URL(fileURLWithPath: "/usr/bin/env"),
                                   ["HOME=" + home, shell, "-lic", script], timeout: 20)
        let lines = result.output.components(separatedBy: .newlines)
        let path = lines.first { $0.hasPrefix("NOODLE_SETUP_PATH:") }.map { String($0.dropFirst(18)) } ?? ""
        let docker = lines.first { $0.hasPrefix("NOODLE_SETUP_DOCKER:") }.map { String($0.dropFirst(20)) } ?? ""
        let onPath = path.split(separator: ":").contains { String($0) == home + "/.local/bin" }
        let version = result.output.components(separatedBy: "NOODLE_SETUP_VERSION:\n").last ?? ""
        let works = result.code == 0 && ToolDiscovery.versionOK("docker", output: version)
        let conflict = !works && !docker.isEmpty ? (docker as NSString).abbreviatingWithTildeInPath : nil
        return (onPath && works, conflict)
    }
}
