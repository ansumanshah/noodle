import SwiftUI

struct KubernetesPorts: View {
    let snapshot: KubernetesSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ports").font(.headline)
            Text(verbatim: "API server: https://127.0.0.1:\(snapshot.apiPort)")
                .font(.callout.monospaced()).textSelection(.enabled)
            Text("LoadBalancer and NodePort services are forwarded to this Mac on these ports\(snapshot.running ? ":" : " when the cluster runs:")")
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(snapshot.ports, id: \.self) { port in
                    Text(verbatim: String(port)).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            if snapshot.ports.isEmpty { Text("No service ports forwarded.").foregroundStyle(.secondary) }
        }
    }
}

struct KubernetesPods: View {
    let pods: [KubernetesPod]
    let error: String
    let running: Bool
    /// True when the cluster has pods, so an empty list means the search hid them all.
    var filtered = false
    @Binding var selection: KubernetesPod.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pods · All namespaces").font(.headline)
            if !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Status.warning).textSelection(.enabled)
            } else if pods.isEmpty && filtered {
                Text("No pods match.").foregroundStyle(.secondary)
            } else if pods.isEmpty {
                Text(running ? "No pods in this cluster." : "Start Kubernetes to see pods.").foregroundStyle(.secondary)
            } else {
                Table(pods, selection: $selection) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Namespace", value: \.namespace)
                    TableColumn("Status", value: \.phase)
                    TableColumn("Ready", value: \.ready)
                    TableColumn("Restarts") { pod in Text("\(pod.restarts)") }
                }
                .standardRows()
                .frame(minHeight: 180, idealHeight: min(420, CGFloat(pods.count) * RowSize.height + 35))
                if let pod = pods.first(where: { $0.id == selection }) {
                    Text("\(pod.namespace)/\(pod.name) · \(pod.phase) · \(pod.ready) ready · \(pod.restarts) restarts")
                        .font(.callout).textSelection(.enabled)
                }
            }
        }
    }
}
