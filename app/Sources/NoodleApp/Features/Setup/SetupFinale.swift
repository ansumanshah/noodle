import Foundation
import SwiftUI

enum SetupComposeCheck: Equatable {
    case idle, checking, available, failed(String)

    static func verify(docker: String, configDirectory: String) async -> CLI.Result {
        let result = await DockerSettingsCommands.run(docker, ["--context", "noodle", "compose", "version"])
        guard result.code != 0 else { return result }
        return await Task.detached {
            let plugin = URL(fileURLWithPath: configDirectory).appendingPathComponent("cli-plugins/docker-compose").path
            let exists = FileManager.default.fileExists(atPath: plugin)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: plugin)) != nil
            let advice = exists
                ? "Existing plugin: \(plugin). Repair or move this plugin before reinstalling. Noodle preserves existing plugins."
                : "Inspect any existing docker-compose plugin in Docker’s other CLI plugin directories. Repair or move a broken copy before reinstalling."
            return CLI.Result(code: result.code, output: String(result.output.suffix(4096)) + "\n" + advice)
        }.value
    }
}

enum SetupApplyWait {
    case setupFiles, socket, dockerVersion, terminal

    var detail: String {
        switch self {
        case .setupFiles: "Applying setup files"
        case .socket: "Waiting for Noodle’s Docker socket"
        case .dockerVersion: "Waiting for docker version"
        case .terminal: "Checking Terminal’s PATH"
        }
    }

    func elapsed(since start: Date, at now: Date) -> String? {
        let seconds = Int(max(0, now.timeIntervalSince(start)))
        return seconds >= 10 ? "\(seconds) s elapsed · \(detail)" : nil
    }
}

struct SetupApplyProgress: View {
    let startedAt: Date
    let waiting: SetupApplyWait

    var body: some View {
        TimelineView(.periodic(from: startedAt.addingTimeInterval(10), by: 1)) { context in
            if let detail = waiting.elapsed(since: startedAt, at: context.date) {
                Text(detail).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SetupComposeNextStep: View {
    let command: String
    let check: SetupComposeCheck

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Start your project from the folder containing compose.yaml.")
                .font(.callout).foregroundStyle(.secondary)
            CommandBlock(command: command)
            if check == .checking {
                HStack(spacing: Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Checking Compose…").font(.callout).foregroundStyle(.secondary)
                }
            }
            if case .failed(let detail) = check {
                SetupList {
                    SetupStatusRow(row: .init(id: "compose", title: String(localized: "Compose needs attention"),
                                             detail: String(localized: "Review the error before reinstalling Compose."), state: .failed))
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                SetupCode(text: "noodle tools install docker-compose")
            }
        }
        .motion(Motion.snappy, value: check)
    }
}
