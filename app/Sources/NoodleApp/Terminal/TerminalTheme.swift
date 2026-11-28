import AppKit

/// Exact palette values from the supplied iTerm2-Color-Schemes exports.
struct TerminalPalette: Sendable {
    let ansi: [String]
    let background: String
    let foreground: String
    let cursor: String
    let selection: String

    private static let syntaxKinds: [ShellSyntax.Kind] = [
        .prompt, .command, .flag, .string, .variable, .operator, .comment, .argument
    ]

    /// Tokens whose published ANSI slot needs the foreground fallback for readable text.
    var fallbackKinds: [ShellSyntax.Kind] {
        Self.syntaxKinds.filter { Self.contrast(originalSyntaxHex(for: $0), background) < 3 }
    }

    func originalSyntaxHex(for kind: ShellSyntax.Kind) -> String {
        switch kind {
        case .prompt, .comment: ansi[8]
        case .command: ansi[4]
        case .flag: ansi[6]
        case .string: ansi[2]
        case .variable: ansi[3]
        case .operator: ansi[5]
        case .argument: foreground
        }
    }

    func syntaxHex(for kind: ShellSyntax.Kind) -> String {
        let original = originalSyntaxHex(for: kind)
        return Self.contrast(original, background) >= 3 ? original : foreground
    }

    /// WCAG contrast ratio from linearized sRGB relative luminance.
    static func contrast(_ first: String, _ second: String) -> Double {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func nsColor(_ hex: String) -> NSColor {
        let rgb = channels(hex)
        return NSColor(srgbRed: CGFloat(rgb.0), green: CGFloat(rgb.1), blue: CGFloat(rgb.2), alpha: 1)
    }

    private static func luminance(_ hex: String) -> Double {
        let rgb = channels(hex)
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }

    private static func channels(_ hex: String) -> (Double, Double, Double) {
        precondition(hex.count == 7 && hex.first == "#", "Expected #RRGGBB")
        guard let value = UInt32(hex.dropFirst(), radix: 16) else {
            preconditionFailure("Expected #RRGGBB")
        }
        return (Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255,
                Double(value & 255) / 255)
    }
}

enum TerminalTheme: String, CaseIterable, Identifiable, Sendable {
    case github, catppuccin
    case tokyoNight = "tokyo-night"
    case rosePine = "rose-pine"
    case solarized

    static let `default`: TerminalTheme = .github
    var id: String { rawValue }
    var title: String {
        switch self {
        case .github: "GitHub"
        case .catppuccin: "Catppuccin"
        case .tokyoNight: "Tokyo Night"
        case .rosePine: "Rose Pine"
        case .solarized: "Solarized"
        }
    }

    func palette(dark: Bool) -> TerminalPalette {
        switch self {
        case .github: dark ? Self.githubDark : Self.githubLight
        case .catppuccin: dark ? Self.catppuccinDark : Self.catppuccinLight
        case .tokyoNight: dark ? Self.tokyoNightDark : Self.tokyoNightLight
        case .rosePine: dark ? Self.rosePineDark : Self.rosePineLight
        case .solarized: dark ? Self.solarizedDark : Self.solarizedLight
        }
    }

    private static let githubLight = TerminalPalette(
        ansi: ["#24292f", "#cf222e", "#116329", "#4d2d00", "#0969da", "#8250df", "#1b7c83", "#6e7781",
               "#57606a", "#a40e26", "#1a7f37", "#633c01", "#218bff", "#a475f9", "#3192aa", "#8c959f"],
        background: "#ffffff", foreground: "#1f2328",
        cursor: "#0969da", selection: "#1f2328")

    private static let githubDark = TerminalPalette(
        ansi: ["#484f58", "#ff7b72", "#3fb950", "#d29922", "#58a6ff", "#bc8cff", "#39c5cf", "#b1bac4",
               "#6e7681", "#ffa198", "#56d364", "#e3b341", "#79c0ff", "#d2a8ff", "#56d4dd", "#ffffff"],
        background: "#0d1117", foreground: "#e6edf3",
        cursor: "#2f81f7", selection: "#e6edf3")

    private static let catppuccinLight = TerminalPalette(
        ansi: ["#bcc0cc", "#d20f39", "#40a02b", "#df8e1d", "#1e66f5", "#ea76cb", "#179299", "#5c5f77",
               "#acb0be", "#e7103f", "#46b02f", "#e49931", "#3878f6", "#ef95d7", "#19a1a8", "#6c6f85"],
        background: "#eff1f5", foreground: "#4c4f69",
        cursor: "#dc8a78", selection: "#dc8a78")

    private static let catppuccinDark = TerminalPalette(
        ansi: ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
               "#585b70", "#f7aec2", "#c2ecbf", "#fcd682", "#aeccfc", "#f398da", "#b1eae1", "#a6adc8"],
        background: "#1e1e2e", foreground: "#cdd6f4",
        cursor: "#f5e0dc", selection: "#f5e0dc")

    private static let tokyoNightLight = TerminalPalette(
        ansi: ["#e9e9ed", "#f52a65", "#587539", "#8c6c3e", "#2e7de9", "#9854f1", "#007197", "#6172b0",
               "#a1a6c5", "#f52a65", "#587539", "#8c6c3e", "#2e7de9", "#9854f1", "#007197", "#3760bf"],
        background: "#e1e2e7", foreground: "#3760bf",
        cursor: "#3760bf", selection: "#99a7df")

    private static let tokyoNightDark = TerminalPalette(
        ansi: ["#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
               "#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5"],
        background: "#1a1b26", foreground: "#c0caf5",
        cursor: "#c0caf5", selection: "#283457")

    private static let rosePineLight = TerminalPalette(
        ansi: ["#f2e9e1", "#b4637a", "#286983", "#ea9d34", "#56949f", "#907aa9", "#d7827e", "#575279",
               "#9893a5", "#b4637a", "#286983", "#ea9d34", "#56949f", "#907aa9", "#d7827e", "#575279"],
        background: "#faf4ed", foreground: "#575279",
        cursor: "#575279", selection: "#dfdad9")

    private static let rosePineDark = TerminalPalette(
        ansi: ["#26233a", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4",
               "#6e6a86", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4"],
        background: "#191724", foreground: "#e0def4",
        cursor: "#e0def4", selection: "#403d52")

    private static let solarizedLight = TerminalPalette(
        ansi: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#bbb5a2",
               "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"],
        background: "#fdf6e3", foreground: "#657b83",
        cursor: "#657b83", selection: "#eee8d5")

    private static let solarizedDark = TerminalPalette(
        ansi: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
               "#335e69", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"],
        background: "#002b36", foreground: "#839496",
        cursor: "#839496", selection: "#073642")
}
