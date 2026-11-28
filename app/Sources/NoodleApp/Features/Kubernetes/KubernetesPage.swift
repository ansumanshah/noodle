import SwiftUI
import AppKit

struct KubernetesPage: View {
    @State private var store: KubernetesStore
    @State private var confirmation: KubernetesStore.Action?
    @State private var windowVisible = false
    @State private var selectedPod: KubernetesPod.ID?
    let search: String

    init(store: KubernetesStore = KubernetesStore(), search: String = "") {
        _store = State(initialValue: store)
        self.search = search
    }

    private func visiblePods(_ pods: [KubernetesPod]) -> [KubernetesPod] {
        pods.filter { ListFilter.matches(search, $0.name, $0.namespace, $0.phase) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Space.l) {
                    if let error = store.statusError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Status.warning)
                            .textSelection(.enabled)
                    }
                    if let snapshot = store.snapshot {
                        if !snapshot.exists && !snapshot.hasData {
                            kubernetesEmptyCard(snapshot)
                        } else {
                            cluster(snapshot).box()
                            KubernetesPorts(snapshot: snapshot).box()
                            kubeconfig(snapshot).box()
                            KubernetesPods(pods: visiblePods(snapshot.pods), error: snapshot.podsError,
                                           running: snapshot.running, filtered: !snapshot.pods.isEmpty, selection: $selectedPod).box()
                        }
                    } else if store.statusError == nil {
                        ProgressView("Loading Kubernetes status…")
                    }
                    if let message = store.message {
                        Text(message).font(.callout).textSelection(.enabled)
                    }
                }
                .padding(Space.page)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .pageSummary(store.snapshot.flatMap { $0.exists || $0.hasData ? "Local cluster · " + Fmt.count($0.pods.count, "pod") : nil })
        .pageActions([PageAction(id: "refresh", title: "Refresh", symbol: "arrow.clockwise",
                                 disabled: store.refreshing || store.action != nil) { Task { await store.refresh() } }])
        .background(KubernetesWindowVisibility { windowVisible = $0 })
        .onChange(of: search) {
            if let id = selectedPod, !visiblePods(store.snapshot?.pods ?? []).contains(where: { $0.id == id }) { selectedPod = nil }
        }
        .task(id: windowVisible) {
            if windowVisible { await store.watch() }
        }
        .onDisappear { windowVisible = false }
        .motion(Motion.snappy, value: store.snapshot?.state)
        .alert(confirmationTitle, isPresented: $confirmation.isPresent()) {
            if let action = confirmation {
                Button(action == .context ? "Use Context" : action == .reset ? "Reset" : "Remove",
                       role: action == .context ? nil : .destructive) { run(action) }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { Text(confirmationMessage) }
    }

    private var disabled: Bool { store.action != nil || store.refreshing || store.statusError != nil }

    private func kubernetesEmptyCard(_ snapshot: KubernetesSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "helm")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(WorkspaceStyle.containers.ink)
                    .frame(width: Tile.hero, height: Tile.hero)
                    .background(WorkspaceStyle.containers.soft, in: .rect(cornerRadius: Radius.card, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lightweight local Kubernetes").font(.title3.weight(.semibold))
                    Text("Single-node k3s cluster running directly inside the Noodle Linux VM.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("Automatic forwarding for LoadBalancer and NodePort services", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.secondary)
                Label("Isolated kubeconfig at ~/.local/share/noodle/kubernetes/kubeconfig", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.secondary)
                Label("Seamless integration with your local Docker images and containers", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.vertical, Space.xxs)
            Divider()
            HStack(spacing: 12) {
                Button("Enable Kubernetes", systemImage: "play.fill") { run(.start) }
                    .buttonStyle(ControlButtonStyle(tint: Status.running))
                    .disabled(disabled || !snapshot.daemonRunning)
                if let action = store.action {
                    ProgressView().controlSize(.small)
                    Text(action.progress).font(.callout).foregroundStyle(.secondary)
                } else if !snapshot.daemonRunning {
                    Text("Start Noodle Containers to enable Kubernetes").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .box(padding: 22)
        .frame(maxWidth: 640)
    }

    private func cluster(_ snapshot: KubernetesSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Local cluster").font(.title3.weight(.semibold))
                    HStack(spacing: 8) {
                        StatePill(state: snapshot.state.lowercased(), pending: store.action?.progress)
                    }
                }
                Spacer()
                if snapshot.running {
                    Button("Stop", systemImage: "stop.fill") { run(.stop) }.buttonStyle(ControlButtonStyle(tint: Status.stopped))
                        .disabled(disabled || !snapshot.daemonRunning)
                } else {
                    Button(snapshot.exists || snapshot.hasData ? "Start" : "Enable", systemImage: "play.fill") { run(.start) }
                        .buttonStyle(ControlButtonStyle(tint: Status.running)).disabled(disabled || !snapshot.daemonRunning)
                }
                Button("Reset", systemImage: "arrow.counterclockwise") { confirmation = .reset }
                    .buttonStyle(ControlButtonStyle(tint: .primary)).disabled(disabled || !snapshot.hasData || !snapshot.daemonRunning)
                Button("Remove", systemImage: "trash") { confirmation = .remove }
                    .buttonStyle(ControlButtonStyle(tint: .primary)).disabled(disabled || !snapshot.hasData || !snapshot.daemonRunning)
            }
            Text(snapshot.version).font(.callout).foregroundStyle(.secondary)
            if !snapshot.daemonRunning {
                Text("Start Noodle Containers to manage Kubernetes.").foregroundStyle(.secondary)
            } else if !snapshot.exists {
                Text("Enable downloads k3s and creates a local cluster.")
                    .foregroundStyle(.secondary)
            } else if !snapshot.running {
                Text("Start the cluster to resume containers.").foregroundStyle(.secondary)
            }
        }
    }

    private func kubeconfig(_ snapshot: KubernetesSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Kubeconfig").font(.headline)
                Spacer()
                Button("Use noodle Context", systemImage: "checkmark.circle.fill") { confirmation = .context }
                    .disabled(disabled || !snapshot.hasKubeconfig || !snapshot.daemonRunning)
            }
            Text(snapshot.kubeconfig).font(.callout.monospaced()).textSelection(.enabled)
            Text(snapshot.hasKubeconfig ? "Use Context adds noodle to ~/.kube/config and makes it current." :
                    "Start Kubernetes to create its isolated kubeconfig.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func run(_ action: KubernetesStore.Action) {
        confirmation = nil
        selectedPod = nil
        Task { await store.perform(action) }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .reset: String(localized: "Reset Kubernetes?")
        case .remove: String(localized: "Remove Kubernetes?")
        case .context: String(localized: "Use the noodle context?")
        default: String(localized: "Kubernetes")
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .reset: String(localized: "This deletes all cluster containers and data, then creates a fresh cluster using the same ports. This cannot be undone.")
        case .remove: String(localized: "This deletes the cluster, containers, data, and isolated kubeconfig. Your ~/.kube/config is kept. This cannot be undone.")
        case .context: String(localized: "This backs up ~/.kube/config, adds the noodle context, and makes it current for kubectl.")
        default: ""
        }
    }
}
