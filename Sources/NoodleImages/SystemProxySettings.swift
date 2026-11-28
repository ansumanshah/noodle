import Foundation
import CFNetwork
import NoodleCore

/// On-demand system settings. CFNetwork already backs URLSession; no watcher or helper is started.
public enum SystemProxySettings {
    public static func read() -> [String: Any] {
        // An explicit daemon-launch override for isolated end-to-end tests, never a persisted setting.
        if let path = ProcessInfo.processInfo.environment["NOODLE_TEST_SYSTEM_PROXY_FILE"] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return settings
        }
        return CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
    }
}
