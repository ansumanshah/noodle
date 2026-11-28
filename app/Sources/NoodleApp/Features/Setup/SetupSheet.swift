import SwiftUI

/// Presents the first-run assistant. Live by default; any `--demo-setup` flag uses scripted answers (no VM, no network),
/// and `--demo-setup-state=<name>` opens straight on one state (see SetupPreview).
struct SetupSheet: View {
    let env: AppEnvironment
    @State private var flow: SetupFlow
    @State private var preview: Bool
    @State private var previouslyCompleted: Bool
    @Environment(\.dismiss) private var dismiss

    init(env: AppEnvironment) {
        self.env = env
        _previouslyCompleted = State(initialValue: !env.connection.needsSetup)
        if let name = AppEnvironment.arg("--demo-setup-state"), let shown = SetupPreview.flow(named: name) {
            _flow = State(initialValue: shown); _preview = State(initialValue: true)
        } else {
            let scripted = env.demo || CommandLine.arguments.contains { $0.hasPrefix("--demo-setup") }
            let backend: any SetupBackend = scripted ? ScriptedSetupBackend() : LiveSetupBackend(env: env)
            _flow = State(initialValue: SetupFlow(backend: backend)); _preview = State(initialValue: false)
        }
    }

    var body: some View {
        SetupSheetContent(flow: flow, close: { finished in
            if !preview { env.finishSetup(finished: finished, previouslyCompleted: previouslyCompleted) }
            if !finished { UserDefaults.standard.set(true, forKey: "setupDismissed") }
            dismiss()
        })
        .task { if !preview, env.nav.canChangeInstallation { flow.begin() } }
        // Closing the window mid-download or mid-import stops that work cleanly.
        .onDisappear {
            if !preview { env.finishSetup(finished: flow.stage == .done, previouslyCompleted: previouslyCompleted) }
            flow.abandon()
        }
    }
}

/// The assistant window: step list on the left, one page on the right, a bottom bar that never moves.
struct SetupSheetContent: View {
    /// Fixed assistant geometry: the window, the step column, and the button bar (also the minimum row height).
    static let size = CGSize(width: 760, height: 500)
    static let stepColumn: CGFloat = 200
    static let barHeight: CGFloat = 56

    let flow: SetupFlow
    let close: (_ finished: Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            SetupSidebar(flow: flow)
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: Control.hairline)
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    SetupPage(flow: flow)
                        .id(flow.current)
                        // The page's container moves first, then its content settles in.
                        .transition(.asymmetric(insertion: .slide(from: .trailing).animation(reduceMotion ? Motion.reduced : Motion.standard.delay(0.06)), removal: .opacity))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: Control.hairline)
                SetupButtons(flow: flow, close: close).padding(.horizontal, Space.page).frame(height: SetupSheetContent.barHeight)
            }
        }
        .frame(width: SetupSheetContent.size.width, height: SetupSheetContent.size.height)
        .tint(WorkspaceStyle.accent)
        .background(Color(nsColor: .windowBackgroundColor))
        .motion(Motion.standard, value: flow.current)
        .motion(Motion.standard, value: flow.stage)
    }
}

struct SetupSidebar: View {
    let flow: SetupFlow

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Image(nsImage: SetupIcon.image).resizable().interpolation(.high).frame(width: Tile.hero, height: Tile.hero)
                .accessibilityLabel("Noodle")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(flow.steps) { step in
                    SetupStepRow(title: step.title, mark: flow.mark(step), current: step == flow.current)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.page)
        .frame(width: SetupSheetContent.stepColumn, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.035))
        .motion(Motion.standard, value: flow.steps.count)
    }
}

/// Small circle for upcoming, filled for current, check for done, orange warning for failed. Same in every appearance.
struct SetupStepRow: View {
    let title: String
    let mark: SetupMark
    let current: Bool
    @Environment(\.productTone) private var tone

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: symbol).imageScale(.medium).symbolRenderingMode(.hierarchical).frame(width: 20)
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
            Text(title).font(.body.weight(current ? .semibold : .regular))
                .foregroundStyle(mark == .upcoming ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
        .background(tone.ink.opacity(current ? 0.13 : 0), in: .rect(cornerRadius: Radius.control, style: .continuous))
        .motion(Motion.snappy, value: mark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(label)")
    }

    private var symbol: String {
        switch mark {
        case .upcoming: "circle"
        case .current: "circle.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch mark {
        case .failed: Status.warning
        case .done: Status.running
        case .upcoming: .secondary
        case .current: tone.ink
        }
    }
    private var label: String {
        switch mark {
        case .upcoming: "upcoming"
        case .current: "current step"
        case .done: "done"
        case .failed: "needs attention"
        }
    }
}
