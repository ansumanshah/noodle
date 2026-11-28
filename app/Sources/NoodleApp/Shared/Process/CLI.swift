import Foundation
import Darwin

/// Finds and runs the `noodle` CLI. The app never reimplements setup logic, it asks the CLI.
enum CLI {
    static let agentLabel = "dev.getnoodle.noodled"

    static var launchAgentPlist: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }
    static var isSetUp: Bool { FileManager.default.fileExists(atPath: launchAgentPlist.path) }

    static func locate() -> URL? {
        let fm = FileManager.default
        var dirs: [String] = []
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            dirs.append(exe.deletingLastPathComponent().appendingPathComponent("Helpers").path)
            // The app executable is named Noodle, which aliases noodle on case-insensitive volumes.
            if Bundle.main.bundleURL.pathExtension != "app" { dirs.append(exe.path) }
        }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let appExecutable = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.executableURL : nil
        let appID = appExecutable.flatMap { try? fm.attributesOfItem(atPath: $0.path)[.systemFileNumber] as? NSNumber }
        let appDevice = appExecutable.flatMap { try? fm.attributesOfItem(atPath: $0.path)[.systemNumber] as? NSNumber }
        for d in dirs {
            let p = d + "/noodle"
            guard fm.isExecutableFile(atPath: p) else { continue }
            if let appID, let appDevice, let attributes = try? fm.attributesOfItem(atPath: p),
               attributes[.systemFileNumber] as? NSNumber == appID, attributes[.systemNumber] as? NSNumber == appDevice { continue }
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    struct Result: Sendable { var code: Int32; var output: String }

    static func run(_ args: [String]) async -> Result {
        guard let exe = locate() else { return Result(code: 127, output: String(localized: "The noodle command line tool was not found. Choose Set Up Noodle… to install it.")) }
        return await Task.detached {
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return Result(code: 126, output: error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return Result(code: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}

extension CLI {
    /// Bounded, cancellable invocation for page-owned work. File output avoids waiting on
    /// pipe descriptors inherited by a CLI child after the CLI itself has timed out.
    static func run(_ args: [String], timeout: TimeInterval) async -> Result {
        guard let exe = locate() else { return Result(code: 127, output: String(localized: "The noodle command line tool was not found. Choose Set Up Noodle… to install it.")) }
        return await run(executable: exe, args, timeout: timeout)
    }

    /// The bounded runner with the executable already chosen; tests point it at a fake CLI.
    static func run(executable exe: URL, _ args: [String], timeout: TimeInterval) async -> Result {
        let invocation = BoundedInvocation()
        return await withTaskCancellationHandler {
            await Task.detached {
                invocation.run(executable: exe, arguments: args, timeout: timeout)
            }.value
        } onCancel: {
            invocation.cancel()
        }
    }
}

extension CLI {
    /// Runs one tool and reports each output line as it arrives (first-run image pull). Cancelling the
    /// task or passing the timeout stops the process. Nothing keeps running after it returns.
    static func stream(executable: String, _ args: [String], environment: [String: String],
                       timeout: TimeInterval, onLine: @escaping @Sendable (String) -> Void) async -> Result {
        let job = SetupPullInvocation(onLine: onLine)
        if Task.isCancelled { job.stop() }
        return await withTaskCancellationHandler {
            await Task.detached { job.run(executable: executable, args, environment: environment, timeout: timeout) }.value
        } onCancel: { job.stop() }
    }
}

extension CLI {
    enum CommandError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let message): message }
        }

        /// The tool's own message, trimmed of its prefix and capped, or the exit status, plus where to see the rest.
        static func readable(_ output: String, status: Int32, command: [String]) -> String {
            let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            let first = lines.first { !$0.isEmpty }.map { $0.hasPrefix("noodle: ") ? String($0.dropFirst(8)) : $0 }
            var reason = first.map { String($0.prefix(300)) } ?? String(localized: "The command stopped with status \(status).")
            if let last = reason.last, !".!?".contains(last) { reason += "." }
            return String(localized: "\(reason) Run “\(command.joined(separator: " "))” in Terminal for details.")
        }
    }

    /// Machine-readable commands keep diagnostics off stdout. All blocking I/O stays off the main actor.
    static func captured(_ args: [String], timeout: TimeInterval = 30) async throws -> Data {
        guard let executable = locate() else {
            throw CommandError.failed(String(localized: "The noodle command line tool was not found. Choose Set Up Noodle… to install it."))
        }
        return try await captured(executable: executable, args, timeout: timeout, includeDiagnostic: true)
    }

    static func captured(executable: URL, _ args: [String], environment: [String: String]? = nil,
                         timeout: TimeInterval, includeDiagnostic: Bool = false) async throws -> Data {
        let job = CapturedJob()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                let output = directory.appendingPathComponent("stdout")
                let diagnostic = directory.appendingPathComponent("stderr")
                try Data().write(to: output)
                try Data().write(to: diagnostic)
                let stdout = try FileHandle(forWritingTo: output)
                let stderr = try FileHandle(forWritingTo: diagnostic)
                defer { try? stdout.close(); try? stderr.close() }
                let process = Process()
                process.executableURL = executable
                process.arguments = args
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = stdout
                process.standardError = includeDiagnostic ? stderr : FileHandle.nullDevice
                try job.start(process)
                let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                deadline.schedule(deadline: .now() + timeout)
                deadline.setEventHandler { job.stop() }
                deadline.resume()
                defer { deadline.cancel() }
                process.waitUntilExit()
                if job.wasStopped { throw CommandError.failed(String(localized: "The command was cancelled or took too long. Try again when ready.")) }
                guard process.terminationStatus == 0 else {
                    let command = [executable.lastPathComponent] + args
                    if !includeDiagnostic {
                        throw CommandError.failed(CommandError.readable("", status: process.terminationStatus, command: command))
                    }
                    let message = String(decoding: try Data(contentsOf: diagnostic), as: UTF8.self)
                    let fallback = String(decoding: try Data(contentsOf: output), as: UTF8.self)
                    throw CommandError.failed(CommandError.readable(message.isEmpty ? fallback : message,
                                                                    status: process.terminationStatus, command: command))
                }
                return try Data(contentsOf: output)
            }.value
        } onCancel: { job.stop() }
    }
}
