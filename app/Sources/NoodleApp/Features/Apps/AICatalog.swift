import Foundation

/// One curated one-click app. It runs as the Compose project `noodle-app-<id>` and is found again from that
/// project label, so an app installed outside the Apps page still shows correctly.
struct AIApp: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
    let about: String
    /// SF Symbol shown on the card.
    let symbol: String
    let category: String
    /// The Mac port the app's web page is published on, bound to localhost only.
    let port: Int
    /// The Compose service that serves the web page.
    let service: String
    let usesModel: Bool
    /// Compose YAML, one line per element, with `{{PORT}}`, `{{MODEL_BASE_URL}}`, `{{MODEL_ID}}` and `{{API_KEY}}` placeholders.
    let compose: [String]

    var project: String { Self.projectPrefix + id }
    static let projectPrefix = "noodle-app-"
    static func isAppProject(_ project: String?) -> Bool { project?.hasPrefix(projectPrefix) == true }

    /// The model a container is pointed at. The address is the Model Runner facade, which containers reach through
    /// `host.docker.internal`; the key is part of that address, so any non-empty key works.
    struct ModelWiring: Equatable, Sendable {
        var baseURL: String
        var modelID: String
        var apiKey = "noodle"
    }

    enum RenderError: LocalizedError, Equatable {
        case needsModel, unsafeValue
        var errorDescription: String? {
            switch self {
            case .needsModel: String(localized: "Your local model address is not available yet. Start Noodle Containers and try again.")
            case .unsafeValue: String(localized: "The local model address has characters that can't be used. Restart Noodle's engine and try again.")
            }
        }
    }

    func render(model: ModelWiring?) throws -> String {
        if usesModel && model == nil { throw RenderError.needsModel }
        var text = compose.joined(separator: "\n") + "\n"
        let values = ["PORT": String(port), "MODEL_BASE_URL": model?.baseURL ?? "", "MODEL_ID": model?.modelID ?? "",
                      "API_KEY": model?.apiKey ?? ""]
        for (key, value) in values {
            // A newline or control character would end the quoted value and could add YAML keys.
            if value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\r" }) {
                throw RenderError.unsafeValue
            }
            // Values sit inside double quotes in the template.
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            text = text.replacingOccurrences(of: "{{\(key)}}", with: escaped)
        }
        return text
    }
}

struct AICatalog: Codable, Sendable {
    let apps: [AIApp]

    static func decode(_ data: Data) throws -> AICatalog { try JSONDecoder().decode(AICatalog.self, from: data) }

    /// The packaged app keeps `apps.json` in Contents/Resources; `swift run` finds it in the SwiftPM resource bundle.
    static let shared = bundled()

    static func bundled() -> AICatalog {
        let url = Bundle.main.url(forResource: "apps", withExtension: "json") ?? Bundle.module.url(forResource: "apps", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url), let catalog = try? decode(data) else { return AICatalog(apps: []) }
        return catalog
    }
}

enum AIAppState: Equatable, Sendable {
    case notInstalled, running, stopped

    var isInstalled: Bool { self != .notInstalled }
}

extension AIApp {
    func containers(in all: [ContainerSummary]) -> [ContainerSummary] { all.filter { $0.project == project } }

    func state(in all: [ContainerSummary]) -> AIAppState {
        let mine = containers(in: all)
        if mine.isEmpty { return .notInstalled }
        return mine.contains(where: \.isRunning) ? .running : .stopped
    }

    /// The app's local `.localhost` name when Noodle serves one, else the published port on this Mac.
    func openURL(in all: [ContainerSummary], names: LocalNameTable) -> URL {
        let web = containers(in: all).first { $0.service == service && $0.isRunning }
        if let web, let link = names.link(for: web) { return link.url }
        return URL(string: "http://localhost:\(web?.ports.compactMap(\.publicPort).first ?? port)")!
    }
}

/// Compose prints one line per layer and container. The card shows one plain sentence instead.
enum AIAppProgress {
    static func words(for line: String) -> String? {
        let text = line.lowercased()
        if text.contains("pull") || text.contains("download") || text.contains("extract") {
            return String(localized: "Downloading the app. The first time takes a few minutes.")
        }
        if text.contains("creat") || text.contains("network") || text.contains("volume") { return String(localized: "Setting things up…") }
        if text.contains("start") { return String(localized: "Starting…") }
        return nil
    }
}

extension AIAppsStore {
    /// The group heading on the Containers page: an app shows its catalog name, not `noodle-app-<id>`.
    static func title(forProject project: String?) -> String {
        guard let project else { return String(localized: "Standalone") }
        return AICatalog.shared.apps.first { $0.project == project }?.name ?? project
    }
}
