import Foundation
import NoodleCore
import NoodleImages

public struct LogOptions: Sendable {
    public var follow = false
    public var stdout = true
    public var stderr = true
    public var since: Int64 = 0
    public var until: Int64 = 0
    public var timestamps = false
    /// -1 means all lines.
    public var tail = -1
    public init() {}
}

// MARK: - logs / attach / exec

extension Engine {
    /// Adds the container's log rotation limits to a guest `create` spec (protocol.md, "Log rotation").
    func withLogLimits(_ op: String, _ args: [String: JSONValue]) -> [String: JSONValue] {
        guard op == GuestOp.create, case .string(let id)? = args["container"], case .object(var spec)? = args["spec"],
              let hc = containers[id]?.hostConfig, let limits = try? LogRotationConfig.validate(hc.LogConfig),
              limits.maxSize > 0 else { return args }
        spec["log_max_size"] = .int(limits.maxSize)
        spec["log_max_file"] = .int(Int64(limits.maxFile))
        var out = args
        out["spec"] = .object(spec)
        return out
    }

    /// Multiplexed log stream (frames kind 1/2, then EOF). Filter stdout/stderr in the API layer with `LogOptions`.
    public func logs(_ ref: String, options: LogOptions = LogOptions()) async throws -> GuestStream {
        let id = try resolveContainerID(ref)
        if containers[id]?.hostConfig.LogConfig.Type == "none" {
            throw EngineError.invalid("configured logging driver does not support reading")   // Docker's wording for `none`
        }
        try await ensureGuestContainer(id)
        var args: [String: JSONValue] = ["container": .string(id), "follow": .bool(options.follow), "tail": .int(Int64(options.tail)),
                                         "timestamps": .bool(options.timestamps)]
        if options.since > 0 { args["since"] = .int(options.since) }
        if options.until > 0 { args["until"] = .int(options.until) }
        return try await runtime(id).guest.openStream(StreamOp.logs, args)
    }

    /// Attach to a running container. Frames: stdin in, stdout/stderr/exit out. With `logs` the guest replays the log first.
    public func attach(_ ref: String, stdin: Bool, stdout: Bool, stderr: Bool, logs: Bool) async throws -> GuestStream {
        let id = try resolveContainerID(ref)
        guard let c = containers[id] else { throw EngineError.notFound("No such container: \(ref)") }
        // `docker run` and `docker start -a` attach before they start the container; the guest tails the log, so created
        // and exited are fine and the stream waits for the next run.
        let stopped = c.status == .created || c.status == .exited
        guard c.status == .running || stopped else {
            throw EngineError.conflict(c.status == .paused ? "Container \(ref) is paused" : "container \(ref) is not running")
        }
        if stopped { try await ensureGuestContainer(id) }
        let stream = try await runtime(id).guest.openStream(StreamOp.attach, ["container": .string(id), "stdin": .bool(stdin), "stdout": .bool(stdout),
                                                                              "stderr": .bool(stderr), "logs": .bool(logs)])
        if let s = containers[id]?.status, s == .created || s == .exited { attachesBeforeStart[id, default: []].append(stream) }
        return stream
    }

    public func resizeContainer(_ ref: String, rows: Int, cols: Int) async throws {
        let id = try resolveContainerID(ref)
        guard containers[id]?.status == .running else { throw EngineError.conflict("Container \(ref) is not running") }
        try await runtime(id).guest.call(GuestOp.resize, ["container": .string(id), "rows": .int(Int64(rows)), "cols": .int(Int64(cols))])
    }
}
