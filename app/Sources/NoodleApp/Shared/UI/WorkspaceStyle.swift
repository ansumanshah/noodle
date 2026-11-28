import SwiftUI
import AppKit

enum WorkspaceStyle {
    /// Where a new window opens, and the smallest the content lays out in (the widest sidebar, 240 pt, leaves 440 pt of page).
    static let defaultWindowSize = CGSize(width: 1000, height: 800)
    static let minWindowSize = CGSize(width: 680, height: 460)
    static let inspectorWindowWidth: CGFloat = 1040

    /// Neutral, and dark enough that a default button never looks disabled behind its white label.
    static let accent = adaptive(dark: 0.42, light: 0.25)
    static let sidebar = adaptive(dark: 0.066, light: 0.951, warmth: 0.012)
    static let content = adaptive(dark: 0.105, light: 0.991, warmth: 0.006)
    static let selection = adaptive(dark: 0.174, light: 0.887, warmth: 0.018)

    /// The three mode tones, defined once for light and dark (each pair is light / dark). `base` for icons and fills,
    /// `soft` for washes behind content, `ink` for text and selection on `soft` or on a `base` tint. Pastels: contrast of
    /// ink on soft and on base at 16% is 5.9 to 8.7 in every tone and appearance; light `base` is at least 3.5 on content.
    struct Tone: Sendable {
        let base: Color
        let soft: Color
        let ink: Color
        /// Hairline of a tinted surface.
        var border: Color { base.opacity(0.35) }
        /// Halo behind a hero tile.
        var glow: Color { base.opacity(0.28) }
    }

    /// Pastels from Catppuccin (MIT): Mocha for dark, Latte deepened for light so icons keep 3:1 on white.
    /// Models: pink.
    static let brand = Tone(base: dynamic(light: 0xc764ad, dark: 0xf5c2e7), soft: dynamic(light: 0xfbecf6, dark: 0x4b4048),
                            ink: dynamic(light: 0x814170, dark: 0xf8d1ed))
    /// Containers: sky.
    static let containers = Tone(base: dynamic(light: 0x038cc3, dark: 0x89dceb), soft: dynamic(light: 0xdff2f9, dark: 0x334549),
                                 ink: dynamic(light: 0x025b7e, dark: 0xa6e5f0))
    /// Runners: green, softer than the saturated system green that Start and "running" use, so a selected tab and
    /// a Start button never read as the same green.
    static let runners = Tone(base: dynamic(light: 0x368825, dark: 0xa6e3a1), soft: dynamic(light: 0xe6f1e3, dark: 0x3a4738),
                              ink: dynamic(light: 0x235818, dark: 0xbceab8))
    static let models = brand

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func rgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        let light = rgb(light), dark = rgb(dark)
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    private static func adaptive(dark: CGFloat, light: CGFloat, warmth: CGFloat = 0) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let shade = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: shade, green: shade - warmth / 2, blue: shade - warmth, alpha: 1)
        })
    }
}

extension Route {
    /// One colour per mode: Containers sky (Overview and Machines included), Runners green, Models pink.
    var tone: WorkspaceStyle.Tone {
        switch self {
        case .overview, .containers, .compose, .images, .volumes, .networks, .builds, .machines, .kubernetes: WorkspaceStyle.containers
        case .runners, .runnerRepos, .runnerJobs, .runnerCaches: WorkspaceStyle.runners
        case .chat, .create, .library, .connections, .apps: WorkspaceStyle.models
        }
    }
}

extension EnvironmentValues {
    /// The product colour of the page being shown. `DetailRouter` sets it per route.
    @Entry var productTone: WorkspaceStyle.Tone = WorkspaceStyle.brand
}

extension View {
    /// A soft product wash fading from the top-leading corner, behind a card or header.
    func toneWash(_ tone: WorkspaceStyle.Tone, radius: CGFloat = Radius.card) -> some View {
        background(LinearGradient(colors: [tone.soft, tone.soft.opacity(0)], startPoint: .topLeading, endPoint: .bottomTrailing),
                   in: .rect(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    /// The inspector: a borderless rounded card that floats over the page.
    func paneCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return background(WorkspaceStyle.sidebar, in: shape)
            .clipShape(shape)
    }
}

extension View {
    /// The page top. The route's name and a count live in the sidebar, so there is no description strip: only the control
    /// that belongs on it, such as filter chips, which sits flush with the list below.
    func pageSummary(_ detail: String?) -> some View { self }

    /// The same top with a control on the trailing edge, such as filter chips.
    func pageSummary<Trailing: View>(_ detail: String?, @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                Spacer(minLength: 0)
                trailing().padding(.trailing, Space.page)
            }
            // Same top inset as every page's first control.
            .padding(.top, Space.page)
            self
        }
    }
}

struct WorkspaceHeading: View {
    let title: String
    let detail: String
    var body: some View {
        // Route names live in the sidebar; an empty title leaves only the summary line.
        VStack(alignment: .leading, spacing: 3) {
            if !title.isEmpty {
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            }
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.page).padding(.top, Space.panel).padding(.bottom, Space.m)
    }
}
