import Foundation

/// Control request. Encodes as one flat JSON object: `{"id":N,"op":"...", ...args}`.
public struct GuestRequest: Sendable {
    public var id: UInt64
    public var op: String
    public var args: [String: JSONValue]
    public init(id: UInt64, op: String, args: [String: JSONValue] = [:]) {
        self.id = id; self.op = op; self.args = args
    }

    public func encodedFrame() throws -> Data {
        var obj = args
        obj["id"] = .int(Int64(id))
        obj["op"] = .string(op)
        let data = try JSONEncoder().encode(JSONValue.object(obj))
        return LengthPrefixed.encode(data)
    }
}

public struct GuestError: Error, Sendable, CustomStringConvertible {
    public var message: String
    public var errno: Int32
    /// True when the agent answered with this error; false for a lost connection or a failed write.
    public var reported = false
    /// `"start"` when the start part of `start` or of `create` with `start` failed.
    public var stage: String?
    public init(_ message: String, errno: Int32 = 0) { self.message = message; self.errno = errno }
    public var description: String { errno == 0 ? message : "\(message) (errno \(errno))" }
}

/// A frame from the guest on the control connection.
public enum GuestMessage: Sendable {
    case response(id: UInt64, result: Result<[String: JSONValue], GuestError>)
    case event(GuestEvent)

    /// Absent means 0; a code that is not an integer in range (1e300) is -1, never a false success.
    private static func exitCode(_ v: JSONValue?) -> Int32 {
        guard let v else { return 0 }
        return v.int.map { Int32(truncatingIfNeeded: $0) } ?? -1
    }

    public static func parse(_ payload: Data) throws -> GuestMessage {
        let v = try JSONDecoder().decode(JSONValue.self, from: payload)
        guard case .object(var o) = v else { throw FrameError.malformed("control frame is not an object") }
        if let ev = o["event"]?.string {
            switch ev {
            case "exit":
                return .event(.exit(container: o["container"]?.string ?? "", code: Self.exitCode(o["code"])))
            case "oom":
                return .event(.oom(container: o["container"]?.string ?? ""))
            case "exec_exit":
                return .event(.execExit(exec: o["exec"]?.string ?? "", code: Self.exitCode(o["code"])))
            case "dns_query":
                return .event(.dnsQuery(id: o["id"]?.int ?? 0, query: Data(base64Encoded: o["query"]?.string ?? "") ?? Data()))
            default:
                return .event(.unknown(ev, o))
            }
        }
        guard let raw = o["id"]?.int, let id = UInt64(exactly: raw) else { throw FrameError.malformed("response without a valid id") }
        let ok = o["ok"]?.bool ?? false
        if ok {
            o.removeValue(forKey: "id"); o.removeValue(forKey: "ok")
            return .response(id: id, result: .success(o))
        }
        var failure = GuestError(o["error"]?.string ?? "guest error", errno: Int32(truncatingIfNeeded: o["errno"]?.int ?? 0))
        failure.reported = true
        failure.stage = o["stage"]?.string
        return .response(id: id, result: .failure(failure))
    }
}

public enum GuestEvent: Sendable {
    case exit(container: String, code: Int32)
    case oom(container: String)
    case execExit(exec: String, code: Int32)
    case dnsQuery(id: Int64, query: Data)
    case unknown(String, [String: JSONValue])
}

/// Names of control ops.
public enum GuestOp {
    public static let dnsAnswer = "dns_answer"
    public static let listPorts = "list_ports"
    public static let ping = "ping", layerHas = "layer_has", layerRemove = "layer_remove"
    public static let create = "create", start = "start", kill = "kill", pause = "pause", unpause = "unpause"
    public static let remove = "remove", update = "update", stats = "stats", top = "top", diff = "diff", resize = "resize"
    public static let netCreate = "net_create", netRemove = "net_remove", netConnect = "net_connect", netDisconnect = "net_disconnect"
    public static let dnsSet = "dns_set", volumeCreate = "volume_create", volumeRemove = "volume_remove", volumeSize = "volume_size"
    public static let fsPoke = "fs_poke", balloonHint = "balloon_hint", setTime = "set_time", shutdown = "shutdown"
    public static let vmUsage = "vm_usage"
}

/// Names of stream ops (on `NoodleWire.streamPort`).
public enum StreamOp {
    public static let attach = "attach", exec = "exec", logs = "logs", unpackLayer = "unpack_layer"
    public static let archiveGet = "archive_get", archivePut = "archive_put", export = "export", layerGet = "layer_get"
    public static let commit = "commit", relayTCP = "relay_tcp", relayUDP = "relay_udp"
}
