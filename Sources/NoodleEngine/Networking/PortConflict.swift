import Foundation

/// Adds the Mac program holding a port to Docker's "port is already allocated" error.
public enum PortConflict {
    /// Docker's message stays first; " (in use by name pid N)" follows when lsof finds the holder.
    /// Blocks up to 3 s per lookup: call it from a detached task, never on the Engine actor or an event loop.
    public static func annotate(_ message: String) -> String {
        guard message.hasSuffix("port is already allocated"),
              let start = message.range(of: "Bind for "), let end = message.range(of: " failed:"),
              let port = message[start.upperBound..<end.lowerBound].split(separator: ":").last.flatMap({ Int($0) }),
              let h = NameListener.holderInfo(of: port) ?? NameListener.holderInfo(of: port, proto: "udp") else { return message }
        return message + " (in use by \(h.name) pid \(h.pid))"
    }

    public static func annotate(_ error: Error) async -> Error {
        guard case EngineError.portInUse(let m) = error else { return error }
        return EngineError.portInUse(await Task.detached { annotate(m) }.value)
    }
}
