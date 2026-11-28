import SwiftUI
import AppKit

/// Icon-only row action, with the same title for its tooltip and VoiceOver label.
struct RowAction: View {
    let title: String
    let symbol: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly).buttonStyle(ControlButtonStyle(tint: tint ?? .primary, square: true)).help(title)
    }
}

/// The empty state: one real command, copyable. Uses noodle directly or docker when Noodle is default.
struct RunCommand: View {
    static let command = "docker --context noodle run -d --name hello -p 8080:80 nginx"
    /// Plain `docker` when it already points at Noodle: the shorter line fits and is what the user would type.
    static func command(elsewhere: Bool) -> String { elsewhere ? command : "docker run -d --name hello -p 8080:80 nginx" }
    var elsewhere = true
    var body: some View {
        InlineCommand(command: Self.command(elsewhere: elsewhere))
    }
}

