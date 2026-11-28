import Foundation

public struct WorkflowFinding: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case ready = "ready"
        case needsMacOS = "needs macOS"
        case macOSForNothing = "pays for macOS it does not need"
        case cannotRunHere = "cannot run here, keep it hosted"
        case hosted = "runs on GitHub, can run here"
        case other = "uses another runner, left alone"
        case unknown = "runs-on is computed, cannot tell"
        case reusable = "calls a reusable workflow, check that file"
    }
    public var file: String
    public var job: String
    public var kind: Kind
    /// A runs-on value to try, or nil when nothing should change.
    public var suggestion: String?

    public var line: String { "\(file) \(job): \(kind.rawValue)" + (suggestion.map { " -> runs-on: \($0)" } ?? "") }
}

/// Reads workflow files and says where each job could run. Never edits anything.
/// shortcut: detection is step-text based (keywords in `run` and `uses`), not a real analysis, so it can be wrong
/// either way. Upgrade only if people rely on it for more than a hint.
public enum WorkflowCheck {
    static let macTools = ["xcodebuild", "xcrun", "setup-xcode", "xcode-select", "simctl", "xcodegen", "brew ", "sw_vers",
                           "hdiutil", "codesign", "pkgbuild", "osascript", "plutil", "lipo ", "ditto ", "launchctl"]
    static let appleSDK = ["macosx", "iphoneos", "iphonesimulator", "xros", "watchos", "appletv"]
    static let x86Marks = ["linux/amd64", "amd64", "x86_64", "x86-64"]

    /// `xcodeMajor`: this Mac's Xcode, so `xcode-N` labels are judged as the helper judges them.
    public static func check(yaml: String, file: String, xcodeMajor: String? = nil) -> [WorkflowFinding] {
        guard let doc = (try? KubeYAML.parse(yaml))?.first, let jobs = doc["jobs"] as? [String: Any] else { return [] }
        return jobs.keys.sorted().compactMap { id in
            guard let job = jobs[id] as? [String: Any] else { return nil }
            if job["runs-on"] == nil, job["uses"] != nil { return WorkflowFinding(file: file, job: id, kind: .reusable, suggestion: nil) }
            let (kind, suggestion) = classify(labels: labels(job["runs-on"]), text: text(job["steps"]).lowercased(), xcodeMajor: xcodeMajor)
            return WorkflowFinding(file: file, job: id, kind: kind, suggestion: suggestion)
        }
    }

    static func labels(_ runsOn: Any?) -> [String] {
        if let s = runsOn as? String { return [s.lowercased()] }
        if let list = runsOn as? [Any] { return list.compactMap { ($0 as? String)?.lowercased() } }
        if let map = runsOn as? [String: Any] { return labels(map["labels"]) }
        return []
    }

    static func text(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let list = any as? [Any] { return list.map(text).joined(separator: "\n") }
        if let map = any as? [String: Any] { return map.map { "\($0.key) \(text($0.value))" }.joined(separator: "\n") }
        return ""
    }

    static func classify(labels: [String], text: String, xcodeMajor: String? = nil) -> (WorkflowFinding.Kind, String?) {
        if labels.isEmpty || labels.contains(where: { $0.contains("${{") }) { return (.unknown, nil) }
        let isMac = labels.contains { $0.hasPrefix("macos") }
        let swiftForApple = (text.contains("swift build") || text.contains("swift test")) && appleSDK.contains { text.contains($0) }
        let needsMac = macTools.contains { text.contains($0) } || swiftForApple
        if labels.contains("noodle") || labels.contains("noodle-macos") {
            // The helper's own rule: a label no Noodle runner carries leaves the job queued forever.
            if RunnerLabels.kind(forJobLabels: labels, xcodeMajor: xcodeMajor) != nil { return (.ready, nil) }
            return (.other, needsMac || isMac || labels.contains("noodle-macos") ? "[self-hosted, noodle-macos]" : "[self-hosted, noodle]")
        }
        if labels.contains(where: { $0.hasPrefix("windows") }) { return (.cannotRunHere, nil) }
        if labels.contains("self-hosted") { return (.other, nil) }
        if needsMac { return (isMac ? .hosted : .needsMacOS, "[self-hosted, noodle-macos]") }
        if isMac { return (.macOSForNothing, "[self-hosted, noodle]") }
        if labels.contains(where: { $0.hasPrefix("ubuntu") && !$0.hasSuffix("arm") }), x86Marks.contains(where: { text.contains($0) }) {
            return (.cannotRunHere, nil)
        }
        return labels.contains { $0.hasPrefix("ubuntu") } ? (.hosted, "[self-hosted, noodle]") : (.other, nil)
    }
}
