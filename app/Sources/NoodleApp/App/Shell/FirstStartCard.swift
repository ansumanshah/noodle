import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class FirstStartNotice {
    private static let dismissedKey = "firstContainerStartCardDismissed"
    private(set) var containerName: String?
    private let defaults: UserDefaults
    /// The card exists to ask for a star once; with no repository to open it has nothing to say.
    private let hasAsk: Bool

    init(defaults: UserDefaults = .standard, hasAsk: Bool = FirstStartNotice.repository != nil) {
        self.defaults = defaults; self.hasAsk = hasAsk
    }

    static var repository: URL? {
        let value = Bundle.main.object(forInfoDictionaryKey: "NoodlePublicGitHubURL") as? String
        return repositoryURL(value)
    }

    static func repositoryURL(_ value: String?) -> URL? {
        guard let value, let parts = URLComponents(string: value),
              parts.scheme == "https", parts.host?.lowercased() == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.split(separator: "/").count == 2 else { return nil }
        return parts.url
    }

    func observe(_ event: DockerEvent) {
        guard event.type == "container", event.action == "start", let name = event.actorName else { return }
        show(name)
    }

    func show(_ name: String) {
        guard hasAsk, containerName == nil, !defaults.bool(forKey: Self.dismissedKey), !name.isEmpty else { return }
        containerName = name
    }

    func dismiss() {
        defaults.set(true, forKey: Self.dismissedKey)
        containerName = nil
    }
}

struct FirstStartCard: View {
    let name: String
    let repository: URL?
    let dismiss: () -> Void
    @Environment(\.productTone) private var tone

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(tone.ink)
                .padding(Space.s)
                .background(tone.ink.opacity(0.14), in: .rect(cornerRadius: Radius.control))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                // "started", not "is running": a `docker run --rm` container is gone before this shows.
                Text("\(name) started").font(.headline).lineLimit(2).help(name)
                if let repository {
                    Text("A GitHub star helps other developers find Noodle.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Star on GitHub", systemImage: "star") {
                            if NSWorkspace.shared.open(repository) { dismiss() }
                        }
                        .buttonStyle(.primaryAction)
                        Button("Not Now", action: dismiss).buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill()
        }
        .padding(Space.panel)
        .frame(width: 350, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 4)
        // It leaves by itself; the task is cancelled when the card goes away first.
        .task {
            try? await Task.sleep(for: Self.stay)
            if !Task.isCancelled { dismiss() }
        }
    }

    static let stay: Duration = .seconds(20)
}
