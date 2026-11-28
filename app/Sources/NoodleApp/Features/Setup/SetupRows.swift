import Foundation
import NoodleCore

/// One line of the first-container list: a name plus one useful fact, and where it stands.
struct SetupProgressRow: Identifiable, Equatable {
    enum State: Equatable { case waiting, active(Double?), done, failed }
    let id: String
    let title: String
    let detail: String
    let state: State
}

extension SetupFlow {
    /// The steps the first-container page shows, in order.
    var progressRows: [SetupProgressRow] {
        let current: Int
        switch stage {
        case .install: current = 0
        case .importing: current = 1
        case .container: current = 2
        case .done: current = 3
        case .failed: current = failedFrom == .container ? 2 : failedFrom == .importing ? 1 : 0
        default: current = -1
        }
        let running = current >= 0 && stage != .failed
        func state(_ index: Int) -> SetupProgressRow.State {
            if index < current { return .done }
            if index > current { return .waiting }
            return stage == .failed ? .failed : .active(index == 2 ? pull.fraction : nil)
        }
        var rows = [SetupProgressRow(id: "install", title: String(localized: "Set up Noodle"), detail: current == 0 && running ? status : "Background service and Docker context",
                                     state: state(0))]
        if importOn, let engine = importEngine {
            rows.append(SetupProgressRow(id: "import", title: String(localized: "Copy from \(engine.displayName)"),
                                         detail: selectedImportInventory.summary, state: state(1)))
        }
        rows.append(SetupProgressRow(id: "container", title: String(localized: "Run a test container"),
                                     detail: current == 2 && running ? (pull.latest.isEmpty ? status : pull.latest) : "alpine",
                                     state: state(2)))
        return rows
    }
}
