import Foundation
import NoodleCore

/// The CLI owns model storage and runner lifecycle. Blocking subprocess IO stays on this queue.
public struct DockerModelCommand: Sendable {
    public typealias Run = @Sendable ([String]) async throws -> Data
    private let queue = DispatchQueue(label: "app.noodle.docker-model.command", qos: .utility)
    private let home: URL
    private let executable: URL

    public init(home: URL, executable: URL? = nil) {
        self.home = home
        self.executable = executable ?? URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("noodle")
    }

    public func run(_ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                        throw DockerModelRunnerError(503, "The noodle CLI must be installed beside noodled")
                    }
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = ["model"] + arguments
                    var environment = ProcessInfo.processInfo.environment
                    environment["NOODLE_HOME"] = home.path
                    environment["NOODLE_LOCAL_NAMES"] = "0"
                    process.environment = environment
                    process.standardInput = FileHandle.nullDevice
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    // Drain while the child runs, even after the capture limit, to avoid pipe deadlock.
                    var captured = Data()
                    var overflow = false
                    while let bytes = try output.fileHandleForReading.read(upToCount: 64 << 10), !bytes.isEmpty {
                        if bytes.count > (1 << 20) - captured.count { overflow = true }
                        if captured.count < 1 << 20 { captured.append(bytes.prefix((1 << 20) - captured.count)) }
                    }
                    process.waitUntilExit()
                    try output.fileHandleForReading.close()
                    guard process.terminationStatus == 0 else {
                        // Endpoint output may contain a key. Never include command output in daemon errors.
                        throw DockerModelRunnerError(500, "Model command \(arguments.first ?? "") failed (exit \(process.terminationStatus)); see noodle model logs")
                    }
                    guard !overflow else { throw DockerModelRunnerError(502, "Model command output exceeds 1 MiB") }
                    continuation.resume(returning: captured)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

public struct DockerModelRunnerError: Error, Sendable, CustomStringConvertible {
    public let status: Int
    public let description: String
    public init(_ status: Int, _ description: String) { self.status = status; self.description = description }
}
