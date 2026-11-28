import Foundation
import Testing
@testable import NoodleApp

@MainActor @Suite struct TerminalTabsTests {
    private func workspace(tabs: Int) -> TerminalWorkspace {
        let w = TerminalWorkspace(socketPath: "/tmp/noodle-test.sock", docker: URL(fileURLWithPath: "/usr/bin/true"), demo: true)
        for _ in 0..<tabs { w.open() }
        return w
    }

    @Test func openSelectsNewTab() {
        let w = workspace(tabs: 2)
        #expect(w.isOpen && w.tabs.count == 2 && w.selectedTab == w.tabs[1].id)
        w.closePanel()
    }

    @Test func closingSelectedTabSelectsLastAndLastCloseClosesPanel() {
        let w = workspace(tabs: 2)
        let first = w.tabs[0].id, second = w.tabs[1].id
        w.closeTab(second)
        #expect(w.selectedTab == first && w.isOpen)
        w.closeTab(first)
        #expect(w.tabs.isEmpty && !w.isOpen && w.selectedTab == nil)
    }

    @Test func reorderKeepsSelectionAndClamps() {
        let w = workspace(tabs: 3)
        let ids = w.tabs.map(\.id)
        w.moveTab(ids[0], to: 99)
        #expect(w.tabs.map(\.id) == [ids[1], ids[2], ids[0]] && w.selectedTab == ids[2])
        w.moveTab(ids[0], to: -5)
        #expect(w.tabs.map(\.id) == ids)
        w.closePanel()
    }

    @Test func cyclingWraps() {
        let w = workspace(tabs: 3)
        let ids = w.tabs.map(\.id)
        w.selectNext()
        #expect(w.selectedTab == ids[0])
        w.selectNext(by: -1)
        #expect(w.selectedTab == ids[2])
        w.closePanel()
    }
}
