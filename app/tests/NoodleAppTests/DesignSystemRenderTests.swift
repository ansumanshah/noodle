import AppKit
import SwiftUI
import Testing
@testable import NoodleApp

/// The shared controls on one row per product tone, to measure heights from the capture: 32 pt controls, 28 pt chips.
@MainActor @Suite(.serialized) struct DesignSystemRenderTests {
    private struct Row: View {
        @State private var query = ""
        @State private var filter = ContainerStatusFilter.all
        var body: some View {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: Control.gap) {
                    SearchField(prompt: "Search", text: $query).frame(width: 200)
                    Button("Import", systemImage: "square.and.arrow.down") {}.buttonStyle(.neutralAction)
                    Button("Save") {}.buttonStyle(.primaryAction)
                    Button("Start", systemImage: "play.fill") {}.buttonStyle(ControlButtonStyle(tint: Status.running))
                    Button("Stop", systemImage: "stop.fill") {}.buttonStyle(ControlButtonStyle(tint: Status.stopped))
                    Button("Refresh", systemImage: "arrow.clockwise") {}.labelStyle(.iconOnly).buttonStyle(.iconAction)
                }
                FilterChips(items: ContainerStatusFilter.allCases, selection: $filter, title: \.title)
                Text("Card").cardSurface().frame(width: 300)
            }
            .padding(Space.page)
        }
    }

    @Test(arguments: [("containers", WorkspaceStyle.containers), ("brand", WorkspaceStyle.brand), ("runners", WorkspaceStyle.runners)])
    func controlsShareOneGeometry(name: String, tone: WorkspaceStyle.Tone) async {
        for dark in [false, true] {
            let r = await RenderHarness.render(Row().environment(\.productTone, tone), name: "design-controls-\(name)\(dark ? "-dark" : "")",
                                               size: CGSize(width: 760, height: 220), dark: dark, recognizeText: false)
            #expect(r.inkRatio > 0.02)
            Self.expectHeights("\(name) \(dark ? "dark" : "light")", tone: tone)
        }
    }

    /// Laid-out heights, measured per control: glass fills sit too close to the page colour for pixel sampling.
    private static func expectHeights(_ label: String, tone: WorkspaceStyle.Tone) {
        @State var query = ""
        @State var filter = ContainerStatusFilter.all
        func height(_ view: some View) -> CGFloat {
            NSHostingView(rootView: view.environment(\.productTone, tone)).fittingSize.height
        }
        let controls = [
            height(SearchField(prompt: "Search", text: $query).frame(width: 200)),
            height(Button("Import", systemImage: "square.and.arrow.down") {}.buttonStyle(.neutralAction)),
            height(Button("Save") {}.buttonStyle(.primaryAction)),
            height(Button("Start", systemImage: "play.fill") {}.buttonStyle(ControlButtonStyle(tint: Status.running))),
            height(Button("Stop", systemImage: "stop.fill") {}.buttonStyle(ControlButtonStyle(tint: Status.stopped))),
            height(Button("Refresh", systemImage: "arrow.clockwise") {}.labelStyle(.iconOnly).buttonStyle(.iconAction)),
        ]
        #expect(controls.allSatisfy { abs($0 - Control.height) <= 0.5 }, "\(label): control heights \(controls)")
        let chips = height(FilterChips(items: ContainerStatusFilter.allCases, selection: $filter, title: \.title))
        #expect(abs(chips - Control.chipHeight) <= 0.5, "\(label): chip row height \(chips)")
    }

    /// Counts live in the sidebar, so a summary alone adds no strip: every page top is the same whatever the text.
    @Test func pageSummaryIsOneStrip() {
        func height(_ detail: String?) -> CGFloat {
            NSHostingView(rootView: Color.clear.frame(width: 600, height: 100).pageSummary(detail)).fittingSize.height
        }
        #expect(height("2 builds") == height("9 images, 4 running"))
        #expect(height("2 builds") == height(nil))
    }

    /// White content hides a dark-mode hairline, so light mode draws a firmer switch outline.
    @Test func lightBordersAreFirmerThanDark() {
        #expect(ColorScheme.light.controlLine > ColorScheme.dark.controlLine)
    }
}
