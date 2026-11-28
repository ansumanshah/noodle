import AppKit
import SwiftUI
import Testing
@testable import NoodleApp

@MainActor @Suite(.serialized) struct CommandRenderingTests {
    @Test func attributedCommandsKeepEveryCharacter() {
        let command = #"$ docker --context=noodle run alpine sh -c 'echo "$HOME" | cat' # café 🥢"#
        for theme in TerminalTheme.allCases {
            for dark in [false, true] {
                let text = CommandHighlight.text(command, palette: theme.palette(dark: dark))
                #expect(String(text.characters) == command)
            }
        }
    }

    @Test func applyingThemeKeepsTheTerminalAndFontSize() {
        let view = EmbeddedTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        defer { view.updateUiClosed() }
        view.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        let process = view.process
        for theme in TerminalTheme.allCases {
            for dark in [false, true] {
                view.applyTheme(theme, dark: dark, tone: WorkspaceStyle.containers)
                // Surface, text and cursor follow the app's tokens; only the ANSI palette is the theme's.
                let accent = TerminalSurfaceColors.resolve(WorkspaceStyle.containers.base, dark: dark)
                #expect(view.nativeBackgroundColor == TerminalSurfaceColors.resolve(WorkspaceStyle.content, dark: dark))
                #expect(view.caretColor == accent)
                #expect(view.selectedTextBackgroundColor == accent.withAlphaComponent(0.35))
                #expect(view.font.pointSize == 17)
                #expect(view.process === process)
                #expect(view.process.shellPid == 0)
            }
        }
    }

    @Test func githubSelectionRemainsReadableInBothModes() {
        let view = EmbeddedTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        defer { view.updateUiClosed() }
        for dark in [false, true] {
            view.applyTheme(.github, dark: dark, tone: WorkspaceStyle.containers)
            #expect(view.selectedTextForegroundColor == view.nativeForegroundColor)
            #expect(view.selectedTextForegroundColor != view.selectedTextBackgroundColor)
        }
    }
}
