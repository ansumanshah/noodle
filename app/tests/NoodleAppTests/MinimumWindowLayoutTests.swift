import SwiftUI
import Testing
@testable import NoodleApp

@Suite struct MinimumWindowLayoutTests {
    /// 680 pt window minus the 240 pt sidebar at its widest.
    private let contentAtMinimumWindow: CGFloat = WorkspaceStyle.minWindowSize.width - 240

    @Test func buildsSplitFitsBesideTheSidebarAtTheMinimumWindow() {
        #expect(BuildsPage.listMinWidth + BuildsPage.detailMinWidth <= contentAtMinimumWindow)
    }

    /// The image list, a 1 pt divider and the pull panel or inspector.
    @Test func imagesSplitFitsBesideTheSidebarAtTheMinimumWindow() {
        #expect(ImagesPage.listMinWidth + 1 + ImagesPage.panelMinWidth <= contentAtMinimumWindow)
    }

    @Test func containersSplitFitsBesideTheSidebarAtTheMinimumWindow() {
        #expect(ContainersPage.listMinWidth + 1 + ContainersPage.detailMinWidth <= contentAtMinimumWindow)
    }
}
