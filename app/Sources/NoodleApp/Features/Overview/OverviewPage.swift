import SwiftUI
import AppKit

/// Landing page. Trouble first, then Projects and Ports, then Memory, Disk and Machines.
/// A tile with nothing real to say is not drawn, and the others fill its row.
struct OverviewPage: View {
    let env: AppEnvironment
    @State private var model = OverviewModel()
    @State private var machines = LinuxMachinesStore()
    @State private var width: CGFloat = 900
    /// Only this window hiding or closing stops the work. Settings and others must not.
    @State private var window: NSWindow?
    /// Hidden until the host window says otherwise, so a page attached to a hidden window never starts anything.
    @State private var windowHidden = true
    @State private var refreshes = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Reading from the daemon is allowed only while it is up and this window can be seen. Demo has no daemon.
    private var active: Bool { env.connection.isUp && (env.demo || !windowHidden) }
    /// Running and paused containers both hold memory.
    private var memoryIDs: [String] { OverviewMemory.ids(env.containers.items) }
    private var exitIDs: [String] {
        OverviewProblems.failing(env.containers.items).filter(OverviewProblems.hasExitTime).map(\.id)
    }
    private var diskKey: DiskKey {
        DiskKey(active: active, images: env.images.items, volumes: env.volumes.items,
                networks: env.networks.items, containers: env.containers.items, refreshes: refreshes)
    }

    private var showProjects: Bool { !env.containers.items.isEmpty || (env.connection.isUp && env.containers.loaded) }
    private var showPorts: Bool { !PortsCard.entries(env.containers.items, names: env.containers.names).isEmpty }
    private var showMemory: Bool { model.hasMemory }
    /// A removable thing keeps the card, even when the daemon counts no bytes for it, because Clean Up lives there.
    private var disk: OverviewDisk? { model.disk.flatMap { $0.used > 0 || $0.reclaimable > 0 || $0.canClean ? $0 : nil } }
    private var layoutKey: [Bool] { [showProjects, showPorts, showMemory, disk != nil, !machines.items.isEmpty] }

    var body: some View {
        let problems = OverviewProblems.items(env, finished: model.finished)
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    ForEach(problems) { AttentionRow(env: env, problem: $0).transition(.slide(from: .top)) }
                }
                .motion(Motion.standard, value: problems.map(\.id))
                if width >= 600 { wide } else { narrow }
            }
            .padding(.horizontal, Space.page).padding(.top, Space.s).padding(.bottom, Space.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .motion(Motion.standard, value: layoutKey)
        }
        .background { wash }
        .background(WorkspaceStyle.content)
        // The same stopped state every Containers section shows, centred over the page.
        .overlay {
            if case .down(let message) = env.connection.phase {
                DaemonDownView(env: env, message: message)
                    .background { wash }.background(WorkspaceStyle.content)
                    .transition(.opacity)
            }
        }
        .motion(Motion.standard, value: env.connection.isUp)
        .overlay(alignment: .top) {
            if let err = env.containers.actionError { ErrorBanner(message: err) { env.containers.actionError = nil } }
        }
        .motion(Motion.snappy, value: env.containers.actionError)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear { machines.configure(demo: env.demo); track() }
        .onDisappear { model.stop() }
        .onChange(of: memoryIDs) { _, _ in track() }
        .onChange(of: active) { _, _ in track() }
        .task(id: active) { if active { await machines.refresh() } }
        .task(id: ExitKey(ids: exitIDs, active: active)) { learnExits() }
        .task(id: diskKey) { await loadDisk() }
        .background(OverviewWindowReader { host in
            window = host
            windowHidden = host.map { !$0.occlusionState.contains(.visible) } ?? true
        }.frame(width: 0, height: 0))
        .onReceive(NotificationCenter.default.publisher(for: .overviewRefresh)) { _ in refreshes += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if note.object as? NSWindow === window { windowHidden = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let changed = note.object as? NSWindow, changed === window else { return }
            windowHidden = !changed.occlusionState.contains(.visible)
        }
    }

    // MARK: layout

    /// Containers-teal washes, fixed behind the scroll.
    private var wash: some View {
        GeometryReader { proxy in
            let side = max(proxy.size.width, proxy.size.height)
            ZStack {
                glow(WorkspaceStyle.containers, at: UnitPoint(x: 0.12, y: 0.08), radius: side * 0.5)
                glow(WorkspaceStyle.containers, at: UnitPoint(x: 0.9, y: 0.04), radius: side * 0.4)
                glow(WorkspaceStyle.containers, at: UnitPoint(x: 0.3, y: 0.85), radius: side * 0.5)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func glow(_ tone: WorkspaceStyle.Tone, at center: UnitPoint, radius: CGFloat) -> some View {
        RadialGradient(colors: [tone.soft.opacity(0.8), tone.soft.opacity(0)], center: center, startRadius: 0, endRadius: radius)
    }

    private var wide: some View {
        VStack(spacing: 20) {
            BentoRow(weights: showProjects && showPorts ? [2, 1] : [1]) {
                if showProjects { ProjectsCard(env: env, finished: model.finished).transition(tile) }
                if showPorts { PortsCard(env: env).transition(tile) }
            }
            BentoRow(weights: [1, 1, 1]) {
                if showMemory { MemoryCard(env: env, model: model).transition(tile) }
                if let disk { DiskCard(env: env, model: model, disk: disk).transition(tile) }
                if !machines.items.isEmpty { MachinesCard(env: env, store: machines).transition(tile) }
            }
        }
    }

    private var narrow: some View {
        VStack(spacing: 20) {
            if showProjects { ProjectsCard(env: env, finished: model.finished).transition(tile) }
            if showPorts { PortsCard(env: env).transition(tile) }
            if showMemory { MemoryCard(env: env, model: model).transition(tile) }
            if let disk { DiskCard(env: env, model: model, disk: disk).transition(tile) }
            if !machines.items.isEmpty { MachinesCard(env: env, store: machines).transition(tile) }
        }
    }

    private var tile: AnyTransition { reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)) }

    // MARK: data

    private struct DiskKey: Equatable {
        var active: Bool
        var images: [ImageSummary]
        var volumes: [VolumeSummary]
        var networks: [NetworkSummary]
        var containers: [ContainerSummary]
        var refreshes: Int
    }

    private struct ExitKey: Equatable { var ids: [String]; var active: Bool }

    private func track() {
        guard active else { model.stop(); return }
        let service = env.service
        model.track(memoryIDs, service: service, oneShot: OverviewMemory.sampler(service: service, socketPath: env.paths.socket.path,
                                                                                 demo: env.demo))
    }

    private func learnExits() {
        // Hidden or down: nothing new starts, and `track()` has already cancelled what was in flight.
        guard active else { return }
        model.learnExits(exitIDs, service: env.service)
    }

    private func loadDisk() async {
        guard env.connection.isUp else { model.setDisk(nil); return }
        guard active else { return }
        // Container events arrive in bursts; one read after they settle is enough.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        if env.demo {
            model.setDisk(OverviewDiskSource.demo(images: env.images.items, containers: env.containers.items))
        } else if let loaded = await OverviewDiskSource.load(socketPath: env.paths.socket.path), !Task.isCancelled {
            model.setDisk(loaded)
        }
    }
}

/// Reports the window hosting the page.
private struct OverviewWindowReader: NSViewRepresentable {
    let changed: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.changed = changed
        return view
    }
    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var changed: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let host = window
            // State writes wait until AppKit finishes updating the representable.
            Task { @MainActor [weak self] in self?.changed?(host) }
        }
    }
}
