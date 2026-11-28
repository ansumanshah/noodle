import SwiftUI

/// The first-run welcome. Live by default; `--demo-welcome` uses scripted answers (no network), and
/// `--demo-welcome-state=<name>` opens straight on one state (see WelcomePreview).
struct WelcomeSheet: View {
    let env: AppEnvironment
    @State private var flow: WelcomeFlow
    @Environment(\.dismiss) private var dismiss

    static var scripted: Bool { CommandLine.arguments.contains { $0.hasPrefix("--demo-welcome") } }

    init(env: AppEnvironment) {
        self.env = env
        if let name = AppEnvironment.arg("--demo-welcome-state"), let shown = WelcomePreview.flow(named: name) {
            _flow = State(initialValue: shown)
        } else if env.demo || Self.scripted {
            _flow = State(initialValue: WelcomeFlow(source: ScriptedWelcomeSource()))
        } else {
            _flow = State(initialValue: WelcomeFlow(source: LiveWelcomeSource(env: env, store: ModelsPage.sharedStore(demo: false))))
        }
    }

    var body: some View {
        @Bindable var flow = flow
        WelcomeSheetContent(flow: flow, close: { dismiss() }, open: { route in
            env.nav.open(.route(route))
            dismiss()
        })
        .task { await flow.source.load() }
        .sheet(item: $flow.sheet) { kind in
            switch kind {
            case .setup: SetupSheet(env: env).compactScrollbars()
            case .addRepo:
                AddRunnerRepoSheet(env: env, existing: Set(env.runnerRepos.items.map(\.repo))) { env.runnerRepos.reload(env: env) }
            }
        }
    }
}

/// The welcome window: one centred page, and Back and Continue centred below it.
struct WelcomeSheetContent: View {
    let flow: WelcomeFlow
    let close: () -> Void
    var open: (Route) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                WelcomePage(flow: flow, open: open)
                    .id(flow.screen)
                    .transition(.asymmetric(insertion: .slide(from: .trailing).animation(reduceMotion ? Motion.reduced : Motion.standard.delay(0.06)),
                                            removal: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            WelcomeButtons(flow: flow, close: close).padding(.bottom, Space.xl)
        }
        .frame(width: SetupSheetContent.size.width, height: SetupSheetContent.size.height)
        .environment(\.productTone, WorkspaceStyle.brand)
        .tint(WorkspaceStyle.accent)
        .background(Color(nsColor: .windowBackgroundColor))
        .motion(Motion.standard, value: flow.screen)
        .motion(Motion.standard, value: flow.products)
    }
}

/// Hero, title, one line and the screen's card, centred.
struct WelcomePage: View {
    let flow: WelcomeFlow
    let open: (Route) -> Void

    var body: some View {
        VStack(spacing: Space.l) {
            VStack(spacing: Space.s) {
                hero
                Text(title).font(.largeTitle.weight(.semibold)).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            switch flow.screen {
            case .choose:
                HStack(spacing: Space.m) {
                    ForEach(WelcomeProduct.allCases) { product in
                        WelcomeTile(product: product, selected: flow.chosen.contains(product)) { flow.toggle(product) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .cardSurface(padding: Space.m, tinted: false)
            case .ready: WelcomeReadyCard(flow: flow)
            case .done: WelcomeDoneCard(flow: flow, open: open)
            }
        }
        .padding(.horizontal, Space.xl * 2)
    }

    @ViewBuilder private var hero: some View {
        if flow.screen == .done {
            Image(systemName: "checkmark.circle.fill").resizable().symbolRenderingMode(.hierarchical)
                .foregroundStyle(Status.running).frame(width: Tile.hero, height: Tile.hero)
                .accessibilityLabel(String(localized: "Done"))
        } else {
            Image(nsImage: SetupIcon.image).resizable().interpolation(.high)
                .frame(width: flow.screen == .choose ? Tile.appIcon : Tile.hero, height: flow.screen == .choose ? Tile.appIcon : Tile.hero)
                .accessibilityLabel("Noodle")
        }
    }

    private var title: String {
        switch flow.screen {
        case .choose: String(localized: "Welcome to Noodle")
        case .ready: String(localized: "Get things ready")
        case .done: String(localized: "You’re set")
        }
    }

    private var subtitle: String {
        switch flow.screen {
        case .choose: String(localized: "Pick what you want on this Mac. You can add the rest later.")
        case .ready: String(localized: "Each one is optional. Nothing changes until you press its button.")
        case .done: String(localized: "Noodle lives in the menu bar. Start with one of these.")
        }
    }
}
