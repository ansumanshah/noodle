import SwiftUI
import AppKit

/// A heading and content on the shared box surface.
struct OverviewCard<Content: View>: View {
    let title: String
    var tone = WorkspaceStyle.containers
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundStyle(tone.ink).accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .box()
        .toneWash(tone)
        .accessibilityElement(children: .contain)
    }
}

enum OverviewStyle {
    static let hover = adaptive(dark: 0.25, light: 0.93)

    private static func adaptive(dark: CGFloat, light: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
        })
    }
}

/// Status dot: green running, orange warning, red failed, gray everything else.
struct OverviewDot: View {
    let color: Color
    var size: CGFloat = 9
    var body: some View {
        Circle().fill(color).frame(width: size, height: size).motion(Motion.snappy, value: color).accessibilityHidden(true)
    }

    static func color(_ c: ContainerSummary, finished: [String: Date] = [:]) -> Color {
        switch c.state {
        case "running": c.status.contains("(unhealthy)") ? Status.warning : Status.running
        case "restarting", "paused": Status.warning
        case "dead": Status.error
        default: OverviewProblems.failing([c], finished: finished).isEmpty ? .gray : Status.error
        }
    }
}

/// A hairline between rows, inset to the text.
struct OverviewDivider: View {
    var body: some View { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5).padding(.leading, 21).accessibilityHidden(true) }
}

extension EnvironmentValues {
    /// True while the row is hovered or any control in it has keyboard focus. Labels can show more then.
    @Entry var overviewRowRevealed = false
}
