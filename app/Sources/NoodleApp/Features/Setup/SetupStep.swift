import SwiftUI
import Observation

/// The four steps in the assistant's left column. Import appears only when another engine has items.
enum SetupStep: Int, CaseIterable, Identifiable {
    case tools, engine, importItems, first
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .tools: "Docker Tools"
        case .engine: "Default Engine"
        case .importItems: "Import"
        case .first: "First Container"
        }
    }

    static func of(_ stage: SetupStage) -> SetupStep {
        switch stage {
        case .detect, .plan, .download: .tools
        case .engine: .engine
        case .importChoice, .importing: .importItems
        default: .first
        }
    }
}
