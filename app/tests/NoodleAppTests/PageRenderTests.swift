import AppKit
import SwiftUI
import Testing
@testable import NoodleApp

/// Every page constructs and renders headless with the demo daemon: no crash, real content, no placeholder text.
/// PNGs land in `app/.build/render/` for review. Serialized because the pages share one demo environment.
@MainActor @Suite(.serialized) struct PageRenderTests {
    private func page<V: View>(_ view: V, _ name: String, route: Route? = nil, size: CGSize = CGSize(width: 900, height: 560),
                               shows: [String], dark: Bool = false, needsInk: Bool = true, compositeAppKitControls: Bool = true,
                               sourceLocation: SourceLocation = #_sourceLocation) async {
        let env = RenderHarness.env
        await env.sync.refreshNow()
        env.nav.search = ""
        if let route { env.nav.route = route }
        // What DetailRouter and SettingsView put around a page: its product tone and the one button style.
        let styled = view.environment(\.productTone, route?.tone ?? WorkspaceStyle.runners).buttonStyle(.neutralAction)
        let r = await RenderHarness.render(styled, name: name + (dark ? "-dark" : ""), size: size, dark: dark,
                                           compositeAppKitControls: compositeAppKitControls)
        if needsInk { #expect(r.inkRatio > 0.02, "\(name) rendered blank", sourceLocation: sourceLocation) }
        for needle in shows {
            #expect(r.contains(needle), "\(name) is missing \"\(needle)\". Saw: \(r.labels.prefix(40))", sourceLocation: sourceLocation)
        }
        for word in placeholderWords {
            #expect(!r.contains(word), "\(name) shows placeholder text \"\(word)\"", sourceLocation: sourceLocation)
        }
    }

    private func inspector(_ tab: ImageTab) -> some View {
        let image = ImageSummary(id: "sha256:8192a3b4c5d6", repoTags: ["alpine:3.22"], size: 8_400_000, created: 1_760_000_000, containers: 1)
        return ImageInspector(env: RenderHarness.env, image: image, initialTab: tab) {}
    }
    private let pane = CGSize(width: 400, height: 640)

    @Test func sidebarCardFollowsMachinePlatform() async {
        let env = RenderHarness.env
        let route = env.nav.route
        let platform = env.nav.machinePlatform
        let phase = env.connection.phase
        defer {
            env.nav.route = route
            env.nav.machinePlatform = platform
            env.connection.phase = phase
        }

        env.nav.route = .machines
        env.nav.machinePlatform = .macOS
        env.connection.phase = .down("Fixture")
        // The engine and VM status now live in the sidebar card, not in a window footer.
        let card = VMStatusPager(env: env).frame(width: 232)
        let size = CGSize(width: 260, height: 300)
        let mac = await RenderHarness.render(card, name: "sidebar-card-macos", size: size)
        #expect(mac.contains("macOS VM"))
        #expect(mac.contains("Set up"))
        // The card shows the selected machine's own state; the footer holds only Refresh and Settings.
        #expect(!mac.contains("Engine stopped"))

        env.nav.machinePlatform = .linux
        let linux = await RenderHarness.render(card, name: "sidebar-card-linux", size: size)
        #expect(linux.contains("Linux machine"))
        #expect(!linux.contains("macOS VM"))
    }

    @Test func sidebarCardPerMode() async {
        let env = RenderHarness.env
        let route = env.nav.route
        defer { env.nav.route = route }
        let card = VMStatusPager(env: env).frame(width: 232)
        for (r, name) in [(Route.chat, "models"), (.containers, "containers"), (.runners, "runners")] {
            env.nav.route = r
            let text = await RenderHarness.render(card, name: "sidebar-card-mode-\(name)", size: CGSize(width: 260, height: 300))
            if r == .chat { #expect(!text.contains("Set Up Noodle")) }
            if r == .runners { #expect(text.contains("Runners")) }
        }
        let modes = ModeSwitcher(nav: env.nav).padding(Space.m)
        _ = await RenderHarness.render(modes, name: "toolbar-mode-switcher", size: CGSize(width: 420, height: 60))
    }

    @Test func imageInfo() async {
        await page(inspector(.info), "image-info", route: .images, size: pane,
                   shows: ["alpine:3.22", "Info", "Layers", "Security", "Size", "Tags", "Containers", "Run Image"])
    }

    @Test func imagePullPanel() async {
        await page(ImagePullPanel(env: RenderHarness.env) {}, "image-pull-panel", route: .images, size: pane,
                   shows: ["Pull Image", "Search", "Image reference", "Pull"])
    }

    @Test func imageLayers() async {
        await page(inspector(.layers), "image-layers", route: .images, size: pane,
                   shows: ["2 steps, 2 stored layers", "apk add", "sha256:4abcf"])
    }

    @Test func imageSecurity() async {
        await page(inspector(.security), "image-security", route: .images, size: pane,
                   shows: ["Vulnerabilities", "Scan Again", "DEMO-2026-0001", "libssl3", "Fixed in 3.1.8",
                           "Packages", "2 packages", "busybox", "Export", "Clear Scan Database"])
    }

    @Test func settingsDocker() async {
        await page(DockerSettings(env: RenderHarness.env), "settings-docker", size: CGSize(width: 710, height: 1000),
                   shows: ["Docker CLI", "Context", "Build cache", "Signed-in registries"])
        #expect(RenderHarness.env.connection.dockerTarget == "Noodle")
    }

    @Test func settingsImport() async {
        await page(ImportSettings(env: RenderHarness.env), "settings-import", size: CGSize(width: 710, height: 480),
                   shows: ["Import from another engine", "Images", "Volumes", "Containers"])
    }

    @Test func settingsDiagnostics() async {
        await page(DiagnosticsSettings(env: RenderHarness.env), "settings-diagnostics", size: CGSize(width: 710, height: 480),
                   shows: ["Engine", "recent lines", "Save Report"])
    }

    @Test func kubernetes() async {
        _ = RenderHarness.env   // demo mode must be on before the store reads it
        let store = KubernetesStore()
        await page(KubernetesPage(store: store), "kubernetes", route: .kubernetes, size: CGSize(width: 900, height: 900),
                   shows: ["API server", "6443", "30000", "kubeconfig", "kube-system", "coredns", "Running", "Restarts"])
    }

    @Test func models() async {
        #expect(ModelsPage(demo: false).store === ModelsPage(demo: false).store)
        #expect(ModelsPage(demo: true).store !== ModelsPage(demo: false).store)
        let wide = CGSize(width: 920, height: 680)
        func capture(_ state: ModelsPageStore.DemoState, _ name: String, shows: [String],
                     tab: Route = .chat, filter: ModelLibraryFilter = .all, size: CGSize? = nil,
                     dark: Bool = false) async {
            let view = ModelsPage(store: ModelsPageStore(demo: true, demoState: state), section: tab,
                                  libraryFilter: filter, inlineHeader: true)
            await page(view, "models-v1-\(name)", route: tab, size: size ?? wide,
                       shows: shows, dark: dark, compositeAppKitControls: false)
        }
        await capture(.installed, "installed", shows: ["Gemma 4 E2B", "Stopped", "Browse Library"])
        await capture(.installed, "library", shows: ["This Mac has", "Import Model", "Gemma 4 E2B", "Installed",
                                                     "On this Mac", "Downloading"], tab: .library)
        await capture(.downloading, "download", shows: ["Downloading model", "43%", "3.35 GB"],
                      tab: .library, filter: .downloading)
        await capture(.verifying, "verify", shows: ["Verifying download", "checksum"], tab: .library, filter: .downloading)
        // New Chat lives in the window toolbar, outside this inline render. Starting adds a status line above the
        // composer, so this capture is taller to keep the composer in frame.
        await capture(.starting, "starting", shows: ["Starting", "Loading the model"], size: CGSize(width: 920, height: 1100))
        await capture(.running, "running", shows: ["Ready", "Noodle", "running locally"])
        await capture(.running, "connections", shows: ["This Mac", "Compose and k3s", "Copy API Key", "Make a request"],
                      tab: .connections, size: CGSize(width: 920, height: 920))
        await capture(.installed, "create", shows: ["Image", "Speech", "Create", "Steps", "FLUX.2 klein", "What you make"], tab: .create)
        await capture(.receiving, "receiving", shows: ["Responding", "Cancel response", "Noodle"])
        await capture(.mlxRunning, "mlx-running", shows: ["Qwen 3 0.6B", "MLX", "Noodle"])
        // The page width beside the widest sidebar at the minimum window: the filter chips wrap instead of scrolling away.
        await capture(.installed, "library-narrow", shows: ["On this Mac", "Available", "Downloading"], tab: .library,
                      size: CGSize(width: WorkspaceStyle.minWindowSize.width - 240, height: 680))
        await capture(.mlxRunning, "mlx-library", shows: ["Qwen 3 0.6B", "Running"], tab: .library)
        await capture(.mlxReceiving, "mlx-receiving-compact",
                      shows: ["Qwen 3 0.6B", "Responding", "Cancel response"],
                      size: CGSize(width: 600, height: 820), dark: true)
        await capture(.firstRun, "first-run", shows: ["Your models. On your Mac.", "Qwen 3.5 4B", "Runs well", "Download"])
        await capture(.firstRun, "library-fit", shows: ["Qwen 3.5 4B", "Llama 70B", "Too big for this Mac"], tab: .library)
        await capture(.memoryShort, "memory-short", shows: ["short on memory", "Close a few apps", "Try Again"])
        await capture(.failed, "error", shows: ["Download failed", "connection dropped", "Try Again", "Dismiss"])
        await capture(.running, "compact", shows: ["Ready", "Noodle"],
                      size: CGSize(width: 600, height: 740), dark: true)
    }

    @Test func linuxMachines() async {
        await page(MachinesPage(env: RenderHarness.env), "machines", route: .machines,
                   shows: ["dev", "Ubuntu 24.04","Open Shell", "noodle machine shell dev", "192.168.64.12", "Delete"])
    }

    @Test func machinesSearchWithNoMatches() async {
        let env = RenderHarness.env
        await env.sync.refreshNow()
        env.nav.search = "zzzz-none"
        let r = await RenderHarness.render(MachinesPage(env: env), name: "machines-no-match")
        // The harness does not capture ContentUnavailableView's text, so the empty state itself cannot be read back.
        // Assert what it can: the page is not blank, and no machine row is listed. The selected machine's detail pane stays.
        #expect(r.inkRatio > 0.02, "a search with no match rendered a blank page")
        for name in env.machines.items.map(\.name) where name != env.nav.selectedMachine {
            #expect(!r.contains(name), "a search with no match still lists \(name)")
        }
        #expect(env.machines.items.count > 1, "the demo needs several machines for this check to mean anything")
        env.nav.search = ""
    }

    @Test func builds() async {
        await page(BuildsPage(env: RenderHarness.env), "builds", route: .builds,
                   shows: ["web:latest", "Build log", "Successfully built"])  // rows are combined accessibility elements, so the harness reads only the selected build
    }

    @Test func containers() async {
        let env = RenderHarness.env
        await env.sync.refreshNow()
        let api = env.containers.items.first { $0.name == "shop-api-1" }
        env.nav.open(container: api?.id ?? "")
        await page(ContainersPage(env: env), "containers-detail", route: .containers, size: CGSize(width: 1200, height: 640),
                   shows: ["shop-api-1", "Overview", "Logs"])
        let names = env.containers.items.map(\.name)
        #expect(names.contains("minio") && names.contains("scratch-alpine"))
        let tint = RenderHarness.tint(RenderHarness.outputDir.appendingPathComponent("containers-detail.png"))
        #expect(tint.red > 200, "running rows need a red stop control")
        #expect(tint.green > 200, "stopped rows need a green start control")
        env.nav.detailContainer = nil
        env.nav.selectedContainers = []
    }

    @Test func images() async {
        await page(ImagesPage(env: RenderHarness.env), "images", route: .images,
                   shows: ["postgres", "redis", "mysql"])
    }

    @Test func volumes() async {
        await page(VolumesPage(env: RenderHarness.env), "volumes", route: .volumes,
                   shows: ["shop_pgdata", "minio-data"])
    }

    @Test func networks() async {
        await page(NetworksPage(env: RenderHarness.env), "networks", route: .networks,
                   shows: ["bridge", "shop_default", "172.18.0.0/16"])
    }

    // MARK: - Runners

    @Test func runnersPages() async {
        let env = RenderHarness.env
        env.runnerRepos.reload(env: env)
        for dark in [false, true] {
            await page(RunnersPage(env: env), "runners-overview", route: .runners,
                       shows: ["Running 1 job(s)", "Holding new jobs", "Running now", "acme/web: lint", "runs-on: [self-hosted, noodle]", "noodle-macos"], dark: dark)
            // The demo switch is on: it must draw green even though the offscreen window is never key.
            let tint = RenderHarness.tint(RenderHarness.outputDir.appendingPathComponent("runners-overview\(dark ? "-dark" : "").png"))
            #expect(tint.green > 400, "the on switch must stay green")
            await page(RunnerReposPage(env: env), "runners-repos", route: .runnerRepos,
                       shows: ["acme/docs", "acme/legacy-api", "Public allowed", "Private only", "macOS runs as you", "Paused",
                               "Resume", "Pause", "Check Workflows", "Remove", "Linux + macOS"], dark: dark)
            await page(RunnerJobsPage(env: env), "runners-jobs", route: .runnerJobs,
                       shows: ["Open on GitHub", "Restoring cache volume", "214 pass"], dark: dark)
            await page(RunnerCachesPage(env: env), "runners-caches", route: .runnerCaches,
                       shows: ["Repo caches", "acme/legacy-api", "has a job running", "macOS runner install", "Job logs", "Clear"], dark: dark)
        }
    }


    private let settingsSize = CGSize(width: 620, height: 460)

    @Test func settingsResources() async {
        await page(ResourcesSettings(env: RenderHarness.env), "settings-resources", size: settingsSize,
                   shows: ["Linux VM", "CPUs", "Memory", "Save"])
    }

    @Test func settingsFileSharing() async {
        await page(SharingSettings(env: RenderHarness.env), "settings-sharing", size: settingsSize, shows: ["Approved folders", "No approved folders", "Add Folder"])
    }

    @Test func settingsAppearance() async {
        await page(AppearanceSettings(), "settings-appearance", size: settingsSize, shows: ["Font size", "Show timestamps"])
    }

    @Test func settingsNetworkPublicLinksFinderProxy() async {
        await page(SettingsNetworkSections(env: RenderHarness.env), "settings-network", size: CGSize(width: 620, height: 900),
                   shows: ["Local names", "Public links", "No public links", "Finder view", "Enable Finder view", "Status", "Proxy", "Mode",
                           "Pass proxy to new containers", "Preview only"])
    }

    @Test func settingsUpdates() async {
        await page(UpdatesSettings(env: RenderHarness.env), "settings-updates", size: settingsSize, shows: ["Version", "Status"])
    }

    @Test func setupSheet() async {
        await page(SetupSheet(env: RenderHarness.env), "setup-sheet", size: CGSize(width: 480, height: 360), shows: ["Noodle"])
    }

    // MARK: - Terminal

    @Test func terminalPanel() async {
        let env = RenderHarness.env
        let workspace = TerminalWorkspace(socketPath: env.paths.socket.path, docker: TerminalLaunch.docker(paths: env.paths), demo: true)
        workspace.open()
        await page(TerminalPanel(workspace: workspace), "terminal", size: CGSize(width: 900, height: 260),
                   shows: ["Shell"])
        await page(TerminalPanel(workspace: workspace), "terminal", size: CGSize(width: 900, height: 260),
                   shows: ["Shell"], dark: true)
        workspace.closePanel()
    }

    // MARK: - Dark appearance spot checks

    /// Pages render light by default: AppKit-backed scroll views resolve dynamic colours against the system
    /// appearance when offscreen, so a dark render of them is not trustworthy. Pages without those views are checked here.
    @Test func darkAppearance() async {
        await page(BuildsPage(env: RenderHarness.env), "builds", route: .builds, shows: ["web:latest"], dark: true)
        await page(MachinesPage(env: RenderHarness.env), "machines", route: .machines, shows: ["Open Shell"], dark: true)
    }
}
