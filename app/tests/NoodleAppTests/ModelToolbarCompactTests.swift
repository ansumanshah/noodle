import NoodleCore
import SwiftUI
import Testing
@testable import NoodleApp

@MainActor @Suite(.serialized) struct ModelToolbarCompactTests {
    /// At the minimum window width the toolbar has about 440 points. The status, picker and Stop must all
    /// fit there without overflowing, and the compact status leaves the backend and model name to the picker.
    @Test func compactHeaderKeepsEveryControlVisibleAtTheMinimumWidth() async {
        let store = ModelsPageStore(demo: true, demoState: .mlxRunning)
        let model = store.models.first { $0.id == store.status.model }
        let header = ModelWorkspaceHeader(store: store, selected: model, select: { _ in }, compact: true)
            .frame(width: 440, alignment: .leading)
            .padding(.vertical, 12)
        let result = await RenderHarness.render(header, name: "models-header-compact-440", size: CGSize(width: 440, height: 80),
                                                dark: true, compositeAppKitControls: false)
        #expect(result.contains("Ready"))
        #expect(result.contains("Qwen 3 0.6B"), "The picker names the running model.")
        #expect(result.contains("Stop"))
        #expect(!result.contains("MLX · Metal"), "The compact status drops the backend.")
    }

    /// The toolbar's host chip shows its whole label or only the dot. It never truncates the label to a stub.
    @Test func hostChipDropsItsWholeLabelWhenSpaceRunsOut() async {
        for (width, label) in [(CGFloat(300), true), (CGFloat(90), false)] {
            let row = HStack(spacing: 0) { HostChip(env: RenderHarness.env).layoutPriority(1); Spacer(minLength: 0) }
                .frame(width: width, alignment: .leading)
                .frame(width: 440, alignment: .leading)
                .padding(.vertical, 12)
            let result = await RenderHarness.render(row, name: "host-chip-\(Int(width))", size: CGSize(width: 440, height: 80),
                                                    dark: true, compositeAppKitControls: false)
            #expect(result.contains("Noodle") == label, "width \(width): \(result.labels)")
            #expect(result.contains("Beta") == label, "width \(width): \(result.labels)")
        }
    }
}
