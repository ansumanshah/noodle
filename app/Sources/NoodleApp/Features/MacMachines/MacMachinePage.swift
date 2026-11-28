import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Virtualization

struct MacMachinePage: View {
    let store: MacMachineStore
    let demo: Bool
    var showsUsageInHeader = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = store.error { ErrorBanner(message: error) { store.error = nil } }
            if let machine = store.machine, store.operation != .starting {
                MacMachineControls(store: store, showsUsage: showsUsageInHeader)
                MacMachineDisplay(machine: machine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let profile = store.profile, let files = store.files {
                            Text("macOS \(profile.osVersion) (\(profile.osBuild))").font(.headline)
                            Text("\(profile.cpus) CPUs · \(profile.memory / MacMachineFiles.gib) GiB RAM")
                                .foregroundStyle(.secondary)
                            Text(files.directory.path).font(.callout.monospaced()).textSelection(.enabled)
                            Button(store.operation == .starting ? "Starting…" : "Start macOS", systemImage: "play.fill") {
                                Task { await store.start() }
                            }
                            .buttonStyle(.primaryAction)
                            .disabled(demo || store.isActive || Updater.shared.status == .installing)
                        } else {
                            MacMachineInstallForm(store: store)
                                .disabled(demo || store.isActive || Updater.shared.status == .installing)
                            if store.operation == .installing {
                                Text("Installing macOS").font(.headline)
                                if let progress = store.installationProgress {
                                    ProgressView(progress).accessibilityLabel("macOS installation progress")
                                    Button("Cancel Installation") { progress.cancel() }.disabled(progress.isCancelled)
                                } else {
                                    ProgressView().controlSize(.small).accessibilityLabel("Checking restore image")
                                }
                            }
                        }
                    }
                    .padding(Space.xl)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { if !demo { store.reload() } }
    }
}

private struct MacMachineInstallForm: View {
    private enum Selection { case restoreImage, storage, existing }

    let store: MacMachineStore
    @State private var picker = Selection.restoreImage
    @State private var browsing = false
    @State private var restoreImage: URL?
    @State private var storage: URL?
    @State private var findingDownload = false
    @State private var download: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(WorkspaceStyle.containers.ink)
                    .frame(width: Tile.hero, height: Tile.hero)
                    .background(WorkspaceStyle.containers.ink.opacity(0.10), in: .rect(cornerRadius: Radius.card, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Run a Mac inside Noodle").font(.title3.weight(.semibold))
                    Text("Install macOS from an Apple restore image (.ipsw) into an isolated APFS virtual disk.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                LabeledContent("Restore image") {
                    HStack(spacing: 8) {
                        if let restoreImage {
                            Text(restoreImage.lastPathComponent).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        } else {
                            Text("No restore image chosen").font(.callout).foregroundStyle(.tertiary)
                        }
                        Button("Choose IPSW…") { browse(.restoreImage) }
                    }
                }
                LabeledContent("Storage folder") {
                    HStack(spacing: 8) {
                        if let storage {
                            Text(storage.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        } else {
                            Text("Requires at least 40 GiB free").font(.callout).foregroundStyle(.tertiary)
                        }
                        Button("Choose Folder…") { browse(.storage) }
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Button("Install macOS") {
                    guard let restoreImage, let storage else { return }
                    Task { await store.install(from: restoreImage, in: storage) }
                }
                .buttonStyle(.primaryAction)
                .disabled(restoreImage == nil || storage == nil)

                Button("Open Existing…") { browse(.existing) }

                Spacer()

                if let download {
                    Link("Download from Apple", destination: download)
                    Button("Copy Link", systemImage: "doc.on.doc") {
                        copyToPasteboard(download.absoluteString)
                    }
                    .buttonStyle(.borderless).hoverFill()
                } else {
                    Button(findingDownload ? "Looking Up…" : "Find Apple Restore Image", systemImage: "arrow.down.circle") {
                        findingDownload = true
                        Task {
                            defer { findingDownload = false }
                            do { download = try await MacMachineStore.appleRestoreImageURL() }
                            catch { store.error = error.localizedDescription }
                        }
                    }
                    .disabled(findingDownload)
                }
            }
        }
        .box(padding: 20)
        .fileImporter(isPresented: $browsing, allowedContentTypes: picker == .restoreImage ? [Self.ipsw] : [.folder]) { result in
            do {
                let url = try result.get()
                switch picker {
                case .restoreImage: restoreImage = url
                case .storage: storage = url
                case .existing: store.openExisting(url)
                }
            } catch { store.error = error.localizedDescription }
        }
    }

    private static let ipsw = UTType(filenameExtension: "ipsw") ?? .data

    private func browse(_ selection: Selection) {
        picker = selection
        browsing = true
    }
}

private struct MacMachineControls: View {
    let store: MacMachineStore
    let showsUsage: Bool
    @State private var confirmingForceStop = false

    var body: some View {
        HStack(spacing: 12) {
            Label(store.statusText, systemImage: "circle.fill")
                .foregroundStyle(store.isRunning ? Status.running : Color.secondary)
                .help(store.shutdownRequested ? "Confirm the shutdown inside macOS if prompted." : "The macOS virtual machine is running.")
            if showsUsage {
                Text("CPU \(store.usage?.cpuText ?? "—")")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Text("Host memory \(store.usage?.memoryText ?? "—")")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            if store.shutdownRequested || store.error != nil {
                Button("Force Stop…") { confirmingForceStop = true }
                    .disabled(store.operation != nil)
            }
            Button(store.shutdownRequested ? "Retry Shutdown" : "Shut Down", systemImage: "stop.fill") { store.requestShutdown() }
                .foregroundStyle(Status.stopped)
                .disabled(store.operation != nil)
        }
        .padding(.horizontal, Space.panel).padding(.vertical, Space.s)
        .confirmationDialog("Force stop macOS?", isPresented: $confirmingForceStop, titleVisibility: .visible) {
            Button("Force Stop", role: .destructive) { Task { await store.forceStop() } }
        } message: {
            Text("This cuts power to the virtual machine. Unsaved changes may be lost.")
        }
    }
}

private struct MacMachineDisplay: NSViewRepresentable {
    let machine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.setAccessibilityLabel("macOS virtual machine display")
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== machine { view.virtualMachine = machine }
    }

    static func dismantleNSView(_ view: VZVirtualMachineView, coordinator: Void) {
        view.virtualMachine = nil
    }
}
