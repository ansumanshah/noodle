import AppKit
import SwiftUI

/// Syntax is built only when SwiftUI asks a visible command view for its body.
enum CommandHighlight {
    static func text(_ command: String, palette: TerminalPalette) -> AttributedString {
        ShellSyntax.tokenize(command).reduce(into: AttributedString()) { result, token in
            var part = AttributedString(token.text)
            part.foregroundColor = Color(nsColor: TerminalPalette.nsColor(palette.syntaxHex(for: token.kind)))
            result.append(part)
        }
    }
}

struct InlineCommand: View {
    let command: String
    /// Breaks onto more lines instead of scrolling, for narrow columns.
    var wraps = false
    @AppStorage("terminalTheme") private var theme = "github"
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = (TerminalTheme(rawValue: theme) ?? .github).palette(dark: scheme == .dark)
        let text = Text(CommandHighlight.text(command, palette: palette))
            .font(.callout.monospaced()).textSelection(.enabled)
        // Takes only the width it needs, and scrolls only when it cannot fit (or wraps, when asked to).
        ViewThatFits(in: .horizontal) {
            text.fixedSize(horizontal: true, vertical: false)
            if wraps {
                text.fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal) { text.fixedSize(horizontal: true, vertical: false) }.scrollIndicators(.never)
            }
        }
        .contextMenu { Button("Copy Command") { copyToPasteboard(command) } }
        .accessibilityLabel(command)
    }
}

struct CommandBlock: View {
    let command: String
    var output = ""
    @AppStorage("terminalTheme") private var theme = "github"
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var copied = false
    @FocusState private var focused: Bool

    var body: some View {
        let palette = (TerminalTheme(rawValue: theme) ?? .github).palette(dark: scheme == .dark)
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(CommandHighlight.text(command, palette: palette))
                    if !output.isEmpty { Text(output).foregroundStyle(Color(nsColor: TerminalPalette.nsColor(palette.foreground))) }
                }
                .font(.callout.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy Command", systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc") {
                copyToPasteboard(command)
                copied = true
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill()
            .foregroundStyle(Color(nsColor: TerminalPalette.nsColor(palette.foreground)))
            .help(copied ? "Copied" : "Copy Command")
            .opacity(hovering || focused ? 1 : 0)
            .allowsHitTesting(hovering || focused)
            .focused($focused)
        }
        .padding(Space.m)
        .background(Color(nsColor: TerminalPalette.nsColor(palette.background)), in: .rect(cornerRadius: Radius.panel, style: .continuous))
        .onHover { hovering = $0; if !$0 { copied = false } }
        .onChange(of: command) { copied = false }
        .onChange(of: focused) { if !focused { copied = false } }
        .motion(Motion.snappy, value: copied)
        .contextMenu { Button("Copy Command") { copyToPasteboard(command) } }
        .accessibilityElement(children: .contain)
    }
}
