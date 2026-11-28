import SwiftUI
import AppKit
import NoodleCore

struct SharingSettings: View {
    let env: AppEnvironment
    @State private var directories: [String] = []
    @State private var note: String?
    @State private var kubernetesFolders = false
    @State private var confirmKubernetes: Bool?
    @State private var confirmRevoke: String?

    var body: some View {
        Form {
            Section {
                if directories.isEmpty { Text("No approved folders").foregroundStyle(.secondary) }
                ForEach(directories, id: \.self) { directory in
                    HStack {
                        Text(directory).textSelection(.enabled)
                        Spacer()
                        Button("Remove") { remove(directory) }.disabled(env.demo)
                    }
                }
                Button("Add Folder…") { add() }.disabled(env.demo)
            } header: {
                Text("Approved folders")
            } footer: {
                Text("Mounting a single file shares its whole folder with the VM, including the files next to it, so Noodle asks you to approve that folder first. Removing a folder affects new containers. Stop running ones to end their access.")
            }
            Section {
                Toggle("Let Kubernetes use your shared folders", isOn: Binding(
                    get: { kubernetesFolders }, set: { confirmKubernetes = $0 })).disabled(env.demo)
            } footer: {
                Text("Pods and privileged containers can read and write the approved folders above through hostPath at the same path. Changing this restarts the VM that runs them.")
            }
            if let note { Text(note).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .confirmationDialog("Restart the VM for Kubernetes and privileged containers?", isPresented: Binding(
            get: { confirmKubernetes != nil }, set: { if !$0 { confirmKubernetes = nil } })) {
            Button(confirmKubernetes == true ? "Share and Restart" : "Stop Sharing and Restart") {
                if let on = confirmKubernetes { Task { await setKubernetesFolders(on) } }
            }
        } message: {
            Text("Containers running in it stop. Run `noodle kubernetes start` afterwards to bring the cluster back with the new setting.")
        }
        .confirmationDialog("End Kubernetes access to this folder now?", isPresented: Binding(
            get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } })) {
            Button("Restart Now") { Task { await setKubernetesFolders(true, restart: true) } }
            Button("Later", role: .cancel) {}
        } message: {
            Text("The VM for Kubernetes and privileged containers keeps access to \(confirmRevoke ?? "the folder") until it restarts. Restarting stops containers in it; run `noodle kubernetes start` afterwards to recreate the cluster node without the folder.")
        }
        .onAppear {
            let s = env.demo ? nil : VMSettings.load(paths: env.paths)
            directories = s?.approvedDirectories ?? []
            kubernetesFolders = s?.workloadSharedFolders == true
        }
    }

    private func setKubernetesFolders(_ on: Bool, restart: Bool = false) async {
        do {
            let body = try JSONEncoder().encode(["Enabled": on, "Restart": restart])
            let reply = try await DockerSocket(path: env.paths.socket.path).request(
                "POST", "/noodle/kubernetes/shared-folders", body: body, contentType: "application/json", timeout: 30)
            guard (200..<300).contains(reply.status) else { note = "Could not change the setting (HTTP \(reply.status))."; return }
            kubernetesFolders = on
            note = restart ? "Restarted. Run `noodle kubernetes start` to recreate the cluster node."
                : on ? "Kubernetes can use your approved folders." : "Kubernetes no longer gets Mac folders."
        } catch { note = "Noodle Containers is not running, so the setting was not changed." }
    }

    private func add() {
        guard !env.demo else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let path = try VMSettings.canonicalDirectory(url.path)
            var settings = VMSettings.load(paths: env.paths)
            if !settings.approvedDirectories.contains(path) { settings.approvedDirectories.append(path) }
            try settings.save(paths: env.paths)
            directories = settings.approvedDirectories
            note = kubernetesFolders ? "Run `noodle kubernetes start` to give the cluster the new folder." : nil
        } catch { note = error.localizedDescription }
    }

    private func remove(_ directory: String) {
        guard !env.demo else { return }
        do {
            var settings = VMSettings.load(paths: env.paths)
            settings.approvedDirectories.removeAll { $0 == directory }
            try settings.save(paths: env.paths)
            directories = settings.approvedDirectories
            note = "Removed. Stop running containers that use it to end their access."
            if kubernetesFolders { confirmRevoke = directory }
        } catch { note = error.localizedDescription }
    }
}
