import Foundation
import NoodleCore
import Observation

/// The three things Noodle offers, in the order the welcome shows them.
enum WelcomeProduct: String, CaseIterable, Identifiable, Hashable {
    case models, containers, runners
    var id: String { rawValue }
    var mode: Route.Mode {
        switch self { case .models: .models; case .containers: .containers; case .runners: .runners }
    }
    var line: String {
        switch self {
        case .models: String(localized: "Chat with AI that runs on your Mac")
        case .containers: String(localized: "Docker, as you know it, faster")
        case .runners: String(localized: "GitHub Actions jobs on this Mac")
        }
    }
}

enum WelcomeScreen: Int, Equatable { case choose, ready, done }

/// A sheet the welcome opens over itself: the existing Docker assistant or the Runners add-repo sheet.
enum WelcomeSheetKind: String, Identifiable { case setup, addRepo; var id: String { rawValue } }

/// What the welcome reads and starts. Live reads the app's stores; scripted is fixed data for demo and previews.
@MainActor protocol WelcomeSource: AnyObject {
    /// The model "Download" fetches, or the chat model already on this Mac.
    var starter: LocalModel? { get }
    var modelReady: Bool { get }
    /// Set while the starter model downloads.
    var progress: LocalModelPullProgress? { get }
    var downloading: Bool { get }
    var modelProblem: String? { get }
    var dockerConnected: Bool { get }
    var repoCount: Int { get }
    /// Live opens the real sheets for Connect and Add repo; scripted finishes them on the spot.
    var opensSheets: Bool { get }
    func download()
    func finish(_ product: WelcomeProduct)
    func load() async
}

/// One welcome: pick products, get each ready, then a start point per product. Screens are pure views of this.
@MainActor @Observable
final class WelcomeFlow {
    /// Set once the welcome has been shown, so it never comes back on its own.
    static let shownKey = "welcomeShown"

    let source: any WelcomeSource
    var screen: WelcomeScreen = .choose
    var chosen: Set<WelcomeProduct> = [.models, .containers]
    var sheet: WelcomeSheetKind?

    init(source: any WelcomeSource) { self.source = source }

    /// The chosen products in display order; screens 2 and 3 show one column each.
    var products: [WelcomeProduct] { WelcomeProduct.allCases.filter(chosen.contains) }
    var canContinue: Bool { !chosen.isEmpty }

    func toggle(_ product: WelcomeProduct) {
        if chosen.contains(product) { chosen.remove(product) } else { chosen.insert(product) }
    }

    func next() {
        guard canContinue, let following = WelcomeScreen(rawValue: screen.rawValue + 1) else { return }
        screen = following
    }

    func back() {
        if let previous = WelcomeScreen(rawValue: screen.rawValue - 1) { screen = previous }
    }

    func isDone(_ product: WelcomeProduct) -> Bool {
        switch product {
        case .models: source.modelReady
        case .containers: source.dockerConnected
        case .runners: source.repoCount > 0
        }
    }

    /// The column's one button: download the starter model, or open the existing sheet for the other two.
    func act(_ product: WelcomeProduct) {
        switch product {
        case .models: source.download()
        case .containers, .runners:
            if source.opensSheets { sheet = product == .containers ? .setup : .addRepo } else { source.finish(product) }
        }
    }

    /// First launch only: a fresh install (setup not done), nothing scripted, never after setup was skipped or the welcome seen.
    static func shouldShow(defaults: UserDefaults = .standard, scripted: Bool, needsSetup: Bool, canChangeInstallation: Bool) -> Bool {
        !scripted && needsSetup && canChangeInstallation
            && !defaults.bool(forKey: shownKey) && !defaults.bool(forKey: "setupDismissed")
    }
}
