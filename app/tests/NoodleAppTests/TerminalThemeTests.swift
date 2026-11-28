// swiftlint:disable line_length
import AppKit
import Foundation
import NoodleCore
import Testing
@testable import NoodleApp

@Suite struct TerminalThemeTests {
    private let kinds: [ShellSyntax.Kind] = [
        .prompt, .command, .flag, .string, .variable, .operator, .comment, .argument
    ]

    @Test func familiesAndDefaultAreStable() {
        #expect(TerminalTheme.default == .github)
        #expect(TerminalTheme.allCases.map(\.rawValue) == [
            "github", "catppuccin", "tokyo-night", "rose-pine", "solarized"
        ])
        #expect(TerminalTheme.allCases.map(\.title) == [
            "GitHub", "Catppuccin", "Tokyo Night", "Rose Pine", "Solarized"
        ])
        #expect(TerminalTheme.allCases.map(\.id) == TerminalTheme.allCases.map(\.rawValue))
    }

    // The literal supplied JSON catches changes to any original palette field or ANSI slot.
    @Test func preservesPublishedPalettes() throws {
        let fixtures = try JSONDecoder().decode([String: [String: Fixture]].self, from: Data(Self.originals.utf8))
        for theme in TerminalTheme.allCases {
            for dark in [false, true] {
                let expected = try #require(fixtures[theme.rawValue]?[dark ? "dark" : "light"])
                let palette = theme.palette(dark: dark)
                #expect(palette.ansi.count == 16)
                #expect(palette.ansi == expected.ansi)
                #expect(palette.background == expected.background)
                #expect(palette.foreground == expected.foreground)
                #expect(palette.cursor == expected.cursor)
                #expect(palette.selection == expected.selection)
            }
        }
    }

    @Test func effectiveSyntaxHasReadableContrast() {
        for theme in TerminalTheme.allCases {
            for dark in [false, true] {
                let palette = theme.palette(dark: dark)
                for kind in kinds {
                    #expect(TerminalPalette.contrast(palette.syntaxHex(for: kind), palette.background) >= 3)
                }
                let slots = [8, 4, 6, 2, 3, 5, 8]
                for (kind, slot) in zip(kinds, slots) {
                    #expect(palette.originalSyntaxHex(for: kind) == palette.ansi[slot])
                }
                #expect(palette.originalSyntaxHex(for: .argument) == palette.foreground)
            }
        }
    }

    @Test func onlyFailingTokensUseForeground() {
        for theme in TerminalTheme.allCases {
            for dark in [false, true] {
                let palette = theme.palette(dark: dark)
                var failures = 0
                for kind in kinds {
                    let original = palette.originalSyntaxHex(for: kind)
                    let fails = TerminalPalette.contrast(original, palette.background) < 3
                    #expect(palette.syntaxHex(for: kind) == (fails ? palette.foreground : original))
                    if fails { failures += 1 }
                }
                #expect(palette.fallbackKinds.count == failures)
                for kind in palette.fallbackKinds {
                    #expect(TerminalPalette.contrast(palette.originalSyntaxHex(for: kind), palette.background) < 3)
                }
            }
        }
        // Published low-contrast slots stay unchanged while syntax alone falls back.
        let light = TerminalTheme.catppuccin.palette(dark: false)
        #expect(light.ansi[8] == "#acb0be")
        #expect(light.syntaxHex(for: .comment) == "#4c4f69")
        #expect(TerminalTheme.github.palette(dark: false).syntaxHex(for: .command) == "#0969da")
    }

    @Test func contrastUsesSRGBRelativeLuminance() {
        #expect(abs(TerminalPalette.contrast("#000000", "#ffffff") - 21) < 0.000001)
        #expect(TerminalPalette.contrast("#123456", "#123456") == 1)
        #expect(abs(TerminalPalette.contrast("#777777", "#ffffff") - 4.478089) < 0.000001)
        #expect(TerminalPalette.contrast("#abcdef", "#123456") ==
                TerminalPalette.contrast("#123456", "#abcdef"))
    }

    @Test func hexConversionKeepsSRGBChannels() throws {
        let color = try #require(TerminalPalette.nsColor("#0969da").usingColorSpace(.sRGB))
        #expect(abs(color.redComponent - 9.0 / 255) < 0.000001)
        #expect(abs(color.greenComponent - 105.0 / 255) < 0.000001)
        #expect(abs(color.blueComponent - 218.0 / 255) < 0.000001)
        #expect(color.alphaComponent == 1)
    }

    private struct Fixture: Decodable {
        let ansi: [String]
        let background: String
        let foreground: String
        let cursor: String
        let selection: String
        enum CodingKeys: String, CodingKey {
            case ansi, background, foreground
            case cursor = "cursor-color"
            case selection = "selection-background"
        }
    }

    private static let originals = #"""
    {
    "github": {"light":{"ansi":["#24292f","#cf222e","#116329","#4d2d00","#0969da","#8250df","#1b7c83","#6e7781","#57606a","#a40e26","#1a7f37","#633c01","#218bff","#a475f9","#3192aa","#8c959f"],"background":"#ffffff","foreground":"#1f2328","cursor-color":"#0969da","selection-background":"#1f2328"},"dark":{"ansi":["#484f58","#ff7b72","#3fb950","#d29922","#58a6ff","#bc8cff","#39c5cf","#b1bac4","#6e7681","#ffa198","#56d364","#e3b341","#79c0ff","#d2a8ff","#56d4dd","#ffffff"],"background":"#0d1117","foreground":"#e6edf3","cursor-color":"#2f81f7","selection-background":"#e6edf3"}},
    "catppuccin": {"light":{"ansi":["#bcc0cc","#d20f39","#40a02b","#df8e1d","#1e66f5","#ea76cb","#179299","#5c5f77","#acb0be","#e7103f","#46b02f","#e49931","#3878f6","#ef95d7","#19a1a8","#6c6f85"],"background":"#eff1f5","foreground":"#4c4f69","cursor-color":"#dc8a78","selection-background":"#dc8a78"},"dark":{"ansi":["#45475a","#f38ba8","#a6e3a1","#f9e2af","#89b4fa","#f5c2e7","#94e2d5","#bac2de","#585b70","#f7aec2","#c2ecbf","#fcd682","#aeccfc","#f398da","#b1eae1","#a6adc8"],"background":"#1e1e2e","foreground":"#cdd6f4","cursor-color":"#f5e0dc","selection-background":"#f5e0dc"}},
    "tokyo-night": {"light":{"ansi":["#e9e9ed","#f52a65","#587539","#8c6c3e","#2e7de9","#9854f1","#007197","#6172b0","#a1a6c5","#f52a65","#587539","#8c6c3e","#2e7de9","#9854f1","#007197","#3760bf"],"background":"#e1e2e7","foreground":"#3760bf","cursor-color":"#3760bf","selection-background":"#99a7df"},"dark":{"ansi":["#15161e","#f7768e","#9ece6a","#e0af68","#7aa2f7","#bb9af7","#7dcfff","#a9b1d6","#414868","#f7768e","#9ece6a","#e0af68","#7aa2f7","#bb9af7","#7dcfff","#c0caf5"],"background":"#1a1b26","foreground":"#c0caf5","cursor-color":"#c0caf5","selection-background":"#283457"}},
    "rose-pine": {"light":{"ansi":["#f2e9e1","#b4637a","#286983","#ea9d34","#56949f","#907aa9","#d7827e","#575279","#9893a5","#b4637a","#286983","#ea9d34","#56949f","#907aa9","#d7827e","#575279"],"background":"#faf4ed","foreground":"#575279","cursor-color":"#575279","selection-background":"#dfdad9"},"dark":{"ansi":["#26233a","#eb6f92","#31748f","#f6c177","#9ccfd8","#c4a7e7","#ebbcba","#e0def4","#6e6a86","#eb6f92","#31748f","#f6c177","#9ccfd8","#c4a7e7","#ebbcba","#e0def4"],"background":"#191724","foreground":"#e0def4","cursor-color":"#e0def4","selection-background":"#403d52"}},
    "solarized": {"light":{"ansi":["#073642","#dc322f","#859900","#b58900","#268bd2","#d33682","#2aa198","#bbb5a2","#002b36","#cb4b16","#586e75","#657b83","#839496","#6c71c4","#93a1a1","#fdf6e3"],"background":"#fdf6e3","foreground":"#657b83","cursor-color":"#657b83","selection-background":"#eee8d5"},"dark":{"ansi":["#073642","#dc322f","#859900","#b58900","#268bd2","#d33682","#2aa198","#eee8d5","#335e69","#cb4b16","#586e75","#657b83","#839496","#6c71c4","#93a1a1","#fdf6e3"],"background":"#002b36","foreground":"#839496","cursor-color":"#839496","selection-background":"#073642"}}
    }
    """#
}
// swiftlint:enable line_length
