import Foundation
import Testing
@testable import NoodleApp

@MainActor @Suite struct QuickAskTests {
    @Test func hotKeyIsOnUnlessSwitchedOff() throws {
        let defaults = try #require(UserDefaults(suiteName: "quickask-\(UUID().uuidString)"))
        #expect(QuickAsk.isEnabled(defaults))
        defaults.set(false, forKey: QuickAsk.defaultsKey)
        #expect(!QuickAsk.isEnabled(defaults))
    }

    @Test func askNoodleTrimsAndRejectsEmptyPrompts() throws {
        #expect(try AskNoodle.cleaned("  hi there \n") == "hi there")
        #expect(throws: AskNoodleError.self) { try AskNoodle.cleaned(" \n") }
    }

    @Test func relaunchDropsFocusFlagButKeepsOthers() {
        let args = Relaunch.arguments(from: ["Noodle", QuickAsk.focusArgument, "--demo"], menuBarOnly: true)
        #expect(args == ["--demo", "--menubar-only"])
    }
}
