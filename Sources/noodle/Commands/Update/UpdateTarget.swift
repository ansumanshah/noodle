import Foundation
import NoodleCore

/// Setup retains a copy of the CLI outside the app. Its LaunchAgent still names the installed
/// daemon, so resolve that bundle instead of treating ~/.local/bin as Contents/Helpers.
func installedUpdateApp() -> URL? {
    func app(containing executable: URL) -> URL? {
        var candidate = executable.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension == "app" { return candidate }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
    if let bundled = app(containing: URL(fileURLWithPath: selfDirectory()).appendingPathComponent("noodle")) { return bundled }
    if let plist = NSDictionary(contentsOf: plistURL) as? [String: Any],
       let daemon = (plist["ProgramArguments"] as? [String])?.first,
       let installed = app(containing: URL(fileURLWithPath: daemon)) { return installed }
    if let target = UpdateStore.load(paths)?.target { return URL(fileURLWithPath: target) }
    return nil
}

func updateHelper(in app: URL) -> String? {
    let path = app.appendingPathComponent("Contents/Helpers/noodle").path
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
}
