import SwiftUI

struct ImageRunForm: View {
    let env: AppEnvironment
    let image: ImageSummary
    let close: () -> Void
    @State private var name = ""
    @State private var running = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run Image").font(.headline)
            TextField("Container name (optional)", text: $name)
                .accessibilityLabel("Container name (optional)")
                .disabled(running).onSubmit { start() }
            Text("Runs the image’s default command with no published ports.")
                .font(.callout).foregroundStyle(.secondary)
            if running { ProgressView("Starting container…") }
            if let error { Text(error).foregroundStyle(Status.error).textSelection(.enabled).frame(maxHeight: 120) }
            HStack {
                Spacer()
                Button("Cancel") { task?.cancel(); close() }
                Button("Run") { start() }.buttonStyle(.primaryAction).disabled(running)
            }
        }
        .onDisappear { task?.cancel() }
    }

    private func start() {
        guard !running else { return }
        running = true
        error = nil
        let containerName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = env.paths
        task = Task {
            let docker = await Task.detached { SetupProbe.discovery(paths).docker() }.value
            guard !Task.isCancelled else { return }
            guard let docker else {
                error = "Docker CLI unavailable. Run noodle tools install."
                running = false
                return
            }
            var args = ["run", "--detach"]
            if !containerName.isEmpty { args += ["--name", containerName] }
            args += ["--", image.id]
            let result = await CLI.stream(executable: docker, args,
                environment: SetupProbe.dockerEnvironment(socket: paths.socket.path), timeout: 60) { _ in }
            guard !Task.isCancelled else { return }
            running = false
            if result.code == 0 {
                do { try await env.containers.refresh() }
                catch { env.containers.actionError = error.localizedDescription }
                if !Task.isCancelled { close() }
            } else {
                let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                error = message.isEmpty ? "Could not run image (\(result.code))." : String(message.suffix(4096))
            }
        }
    }
}
