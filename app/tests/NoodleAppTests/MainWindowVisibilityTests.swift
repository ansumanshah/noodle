import Testing
@testable import NoodleApp

@Suite struct MainWindowVisibilityTests {
    @Test func closingOneMainWindowKeepsTheOtherVisible() {
        let windows = [MainWindowVisibility.Window(id: 1, isMain: true, visible: true),
                       MainWindowVisibility.Window(id: 2, isMain: true, visible: true)]
        #expect(MainWindowVisibility.isVisible(windows, excluding: 1))
        #expect(MainWindowVisibility.isVisible(windows, excluding: 2))
        #expect(!MainWindowVisibility.isVisible(Array(windows.prefix(1)), excluding: 1))
    }

    @Test func settingsAndHiddenMainWindowsDoNotKeepSyncRunning() {
        let windows = [MainWindowVisibility.Window(id: 1, isMain: true, visible: true),
                       MainWindowVisibility.Window(id: 2, isMain: false, visible: true),
                       MainWindowVisibility.Window(id: 3, isMain: true, visible: false)]
        #expect(!MainWindowVisibility.isVisible(windows, excluding: 1))
        #expect(!MainWindowVisibility.isVisible(windows, appHidden: true))
        #expect(MainWindowVisibility.isVisible(windows))
        #expect(!MainWindowVisibility.isVisible([]))
    }
}

@Suite struct WindowCloseWorkTests {
    @Test func idleCloseHandsOffToTheMenuBarProcess() {
        #expect(!WindowCloseWork().keepsProcess)
    }

    @Test func runningWorkKeepsThisProcess() {
        let running: [WindowCloseWork] = [.init(macMachine: true), .init(models: true), .init(modelCreate: true),
                                          .init(appInstalls: 1), .init(composeActions: 1), .init(kubernetes: .start)]
        for work in running { #expect(work.keepsProcess, "\(work)") }
    }
}
