import SwiftUI

struct StateDot: View {
    let state: String
    var size: CGFloat = 8
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .motion(Motion.snappy, value: state)
            .accessibilityHidden(true)
    }
    private var color: Color {
        switch state {
        case "running": Status.running
        case "dead", "failed": Status.error
        default: .gray
        }
    }
}

struct StatePill: View {
    let state: String
    var pending: String?
    var body: some View {
        HStack(spacing: 5) {
            if pending != nil { ProgressView().controlSize(.mini) } else { StateDot(state: state, size: 6) }
            Text(pending ?? state.capitalized).contentTransition(.interpolate)
                .foregroundStyle(pending == nil && state == "running" ? AnyShapeStyle(Status.running)
                                 : pending == nil && (state == "dead" || state == "failed") ? AnyShapeStyle(Status.error)
                                 : AnyShapeStyle(.secondary))
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
        .background(tint.opacity(0.12), in: Capsule())
        .motion(Motion.snappy, value: pending)
        .motion(Motion.snappy, value: state)
    }
}

/// A page or pane with nothing to show. Centred a little above the middle, with a tinted symbol tile, one line of
/// guidance, an optional copyable command and up to two buttons. `compact` is for detail panes and search misses.
extension StatePill {
    fileprivate var tint: Color {
        guard pending == nil else { return .secondary }
        switch state {
        case "running": return Status.running
        case "dead", "failed": return Status.error
        default: return .secondary
        }
    }
}

extension EnvironmentValues {
    /// The docs page for the page being shown, linked from its full-size empty state. `DetailRouter` sets it.
    @Entry var docsURL: URL?
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var command: String?
    var action: (title: String, disabled: Bool, run: () -> Void)?
    var secondary: (title: String, run: () -> Void)?
    var hint: String?
    var compact = false
    @Environment(\.productTone) private var tone
    @Environment(\.docsURL) private var docs

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
            Spacer(minLength: 0)   // two below, one above: the block sits at about a third of the height
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(spacing: compact ? 6 : 8) {
            // One spoken element with a heading role, as the system placeholder it replaces had.
            VStack(spacing: compact ? 6 : 8) {
                tile.padding(.bottom, compact ? 2 : 6)
                Text(title).font(compact ? .headline : .title3.weight(.semibold))
                    .textSelection(.enabled)
                if !message.isEmpty {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message.isEmpty ? title : "\(title). \(message)")
            .accessibilityAddTraits(.isHeader)
            if let command {
                CommandBlock(command: command).frame(maxWidth: 420).padding(.top, Space.s)
            }
            if action != nil || secondary != nil {
                HStack(spacing: 8) {
                    if let action {
                        Button(action.title, action: action.run).buttonStyle(.primaryAction).disabled(action.disabled)
                    }
                    if let secondary {
                        Button(secondary.title, action: secondary.run).buttonStyle(.neutralAction)
                    }
                }
                .padding(.top, command == nil ? Space.s : Space.xs)
            }
            if let hint { Text(hint).font(.footnote).foregroundStyle(.secondary).padding(.top, Space.xxs) }
            if !compact, let docs {
                // Plain text, so it reads as a link under the buttons and not as a third button.
                Link("Learn more", destination: docs).buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                    .underline().padding(.top, Space.s)
            }
        }
        .frame(maxWidth: compact ? 320 : 440)
        .padding(.horizontal, Space.xl).padding(.vertical, Space.page)
    }

    private var warning: Bool { symbol.hasPrefix("exclamationmark") }

    private var tile: some View {
        let side: CGFloat = compact ? 40 : 56
        let tint: Color = warning ? Status.warning : compact ? .secondary : tone.ink
        let fill: Color = warning ? Status.warning.opacity(0.10) : compact ? Color.primary.opacity(0.06) : tone.soft
        return Image(systemName: symbol)
            .font(.system(size: compact ? 17 : 24, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .glassSurface(radius: compact ? 10 : 14)
            .background(fill, in: .rect(cornerRadius: compact ? 10 : 14, style: .continuous))
            .accessibilityHidden(true)
    }

    static func search(_ text: String) -> EmptyState {
        EmptyState(symbol: "magnifyingglass", title: String(localized: "No results for “\(text)”"), message: String(localized: "Check the spelling or try another search."),
                   compact: true)
    }
}

struct LoadingState: View {
    let label: String
    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.regular)
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle").font(.title3.weight(.medium)).foregroundStyle(Status.error)
            Text(message).font(.callout).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark", action: dismiss).labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.panel).padding(.vertical, Space.s)
        .glassSurface(radius: Radius.card)
        .errorSurface()
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(Space.s)
        .transition(.slide(from: .top))
    }
}

struct Card<Content: View>: View {
    let title: String
    var symbol: String?
    var minHeight: CGFloat = 0
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .frame(minHeight: minHeight, alignment: .topLeading)
        .cardSurface(tinted: false)
    }
}
