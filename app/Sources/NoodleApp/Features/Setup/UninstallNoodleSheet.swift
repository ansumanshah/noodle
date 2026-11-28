import AppKit
import SwiftUI

struct UninstallNoodleSheet: View {
    let env: AppEnvironment
    @State private var flow: UninstallFlow
    @Environment(\.dismiss) private var dismiss

    init(env: AppEnvironment, flow: UninstallFlow = UninstallFlow()) {
        self.env = env
        _flow = State(initialValue: flow)
    }

    var body: some View {
        @Bindable var flow = flow
        VStack(alignment: .leading, spacing: 20) {
            SetupPageHeader(title: flow.succeeded ? "Noodle is uninstalled" : "Uninstall Noodle?",
                            detail: String(localized: "The app stays in Applications. Move it to the Trash after quitting."))
            if let result = flow.result {
                if result.code != 0 { Text("Uninstall could not finish. Review the result and try again.").font(.callout) }
                ScrollView {
                    Text(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.callout.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            } else {
                VStack(alignment: .leading, spacing: Space.m) {
                    ForEach(UninstallNoodle.removals, id: \.self) { line in
                        Text(line).font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !flow.succeeded {
                Text(UninstallNoodle.resolvedDataPath(env.paths.root))
                    .font(.callout.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Toggle("Also delete containers, images and volumes", isOn: $flow.deleteData)
                    .toggleStyle(.checkbox).disabled(flow.running)
                Text(flow.deleteData
                     ? "Permanently deletes everything in this folder, including any files you placed there."
                     : "Keeps the Noodle data folder, including containers, images, volumes, downloaded tools and models.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Keychain trust stays in place. Stop running Linux machines before uninstalling.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if flow.succeeded {
                    Spacer()
                    Button("Quit Noodle") { NSApp.terminate(nil) }.buttonStyle(.primaryAction).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(flow.running)
                    Spacer()
                    if flow.running { ProgressView().controlSize(.small) }
                    Button(flow.running ? "Uninstalling…" : "Uninstall Noodle", role: .destructive) { uninstall() }
                        .buttonStyle(ControlButtonStyle(tint: Status.stopped))
                        .disabled(flow.running || env.demo || env.macMachine.isActive || !env.nav.canChangeInstallation)
                }
            }
            .buttonStyle(.neutralAction)
        }
        .padding(Space.page).frame(width: 520)
        .interactiveDismissDisabled(flow.running || flow.succeeded)
        .motion(Motion.snappy, value: flow.running)
        .motion(Motion.standard, value: flow.result?.code)
    }

    private func uninstall() {
        guard !env.demo, !env.macMachine.isActive else { return }
        Task { await env.uninstall(using: flow) }
    }
}
