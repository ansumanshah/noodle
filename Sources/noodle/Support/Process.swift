import Foundation
import NoodleCore

func which(_ name: String) -> String? {
    findExecutable(name, environment: env, home: home) ?? (name == "docker" ? bundledDocker() : nil)
}

@discardableResult
func run(_ exe: String, _ args: [String], extraEnv: [String: String] = [:], capture: Bool = true,
         input: FileHandle? = nil) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var e = env
    for (k, v) in extraEnv { e[k] = v }
    p.environment = e
    if let input { p.standardInput = input }
    let pipe = Pipe()
    if capture { p.standardOutput = pipe; p.standardError = pipe }
    do { try p.run() } catch { return (127, error.localizedDescription) }
    let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// The docker CLI keeps contexts under DOCKER_CONFIG; point it at $HOME/.docker so a fake HOME stays contained.
let dockerEnv: [String: String] = env["DOCKER_CONFIG"] == nil ? ["DOCKER_CONFIG": home + "/.docker"] : [:]

/// The environment for a docker child that must talk to the Noodle engine, whatever context the user has selected.
var engineDockerEnvironment: [String: String] {
    var e = env.merging(dockerEnv) { $1 }
    e["DOCKER_HOST"] = "unix://" + socketPath
    e["DOCKER_CONTEXT"] = nil
    return e
}

/// Runs `executable` with stdin closed and kills it after `timeout` seconds, reporting exit 124 then. Returns stdout,
/// plus stderr unless `errorOutput` takes it, trimmed. With `stdout` set, stdout goes there and is not returned.
@discardableResult
func runWithTimeout(_ executable: String, _ arguments: [String], environment: [String: String] = env, timeout: Double,
                    stdout: FileHandle? = nil, errorOutput: FileHandle? = nil) -> (code: Int32, out: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = stdout ?? pipe
    process.standardError = errorOutput ?? pipe
    do { try process.run() } catch { return (127, error.localizedDescription) }
    let deadline = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
    // Reading a pipe the child never got would wait forever on this process's own write end.
    let data = stdout == nil || errorOutput == nil ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
    deadline.cancel()
    let killed = process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL
    return (killed ? 124 : process.terminationStatus,
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

private final class BlockingBox<T>: @unchecked Sendable { var value: Result<T, Error>? }

/// Runs async work to completion from synchronous command code.
func blocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let box = BlockingBox<T>(), done = DispatchSemaphore(value: 0)
    Task {
        do { box.value = .success(try await operation()) } catch { box.value = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.value!.get()
}
