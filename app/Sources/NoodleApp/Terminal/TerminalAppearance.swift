import AppKit
import SwiftTerm
import SwiftUI

extension EmbeddedTerminalView {
    /// Public SwiftTerm setters repaint the existing view without touching its PTY.
    func applyTheme(_ theme: TerminalTheme, dark: Bool, tone: WorkspaceStyle.Tone) {
        let accent = TerminalSurfaceColors.resolve(tone.base, dark: dark)
        let key = theme.rawValue + (dark ? ":dark" : ":light") + accent.description
        guard appliedTheme != key else { return }
        appliedTheme = key
        let palette = theme.palette(dark: dark)
        installColors(palette.ansi.map { hex in
            let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
            return SwiftTerm.Color(red8: UInt16((rgb >> 16) & 255), green8: UInt16((rgb >> 8) & 255), blue8: UInt16(rgb & 255))
        })
        // The ANSI palette stays the theme's; surface, text, cursor and selection come from the app's tokens.
        let foreground = TerminalSurfaceColors.resolve(SwiftUI.Color(nsColor: .labelColor), dark: dark)
        nativeBackgroundColor = TerminalSurfaceColors.resolve(WorkspaceStyle.content, dark: dark)
        nativeForegroundColor = foreground
        caretColor = accent
        selectedTextBackgroundColor = accent.withAlphaComponent(0.35)
        selectedTextForegroundColor = foreground
        let mono = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
        if font != mono { font = mono }
    }
}

enum TerminalSurfaceColors {
    /// A dynamic app colour frozen for one appearance, since SwiftTerm paints with plain colours.
    static func resolve(_ color: SwiftUI.Color, dark: Bool) -> NSColor {
        var out = NSColor.clear
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            out = NSColor(color).usingColorSpace(.sRGB) ?? .clear
        }
        return out
    }
}
