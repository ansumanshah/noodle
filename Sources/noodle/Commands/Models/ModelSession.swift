import Darwin
import Foundation
import NoodleCore

extension ModelRunner {
    struct Session: Codable {
        let id: String
        var model: String
        let host: String
        let port: Int
        let executable: String
        var backend: LocalModelBackend?
        var process: ProcessIdentity?
        var ownsProcessGroup: Bool?
        var namedRoute: ModelNameRoute.Lease?
        var namedBaseURL: URL?
        /// Set when saved, before the launch child registers. Absent in older session files.
        var created: Date?
        /// One idle eviction policy applies to the shared process.
        var keepAlive: LocalModelKeepAlive?
        /// Crash restarts by the launch supervisor, and the log tail of the latest crash.
        var restarts: Int?
        var lastCrash: String?

        var resolvedBackend: LocalModelBackend { backend ?? .llamaCPP }
        var baseURL: URL? {
            URL(string: "http://\(host):\(port)/v1")
        }
        var workloadBaseURL: URL? {
            host == "127.0.0.1" ? nil : URL(string: "http://\(host):\(port)/v1")
        }

        func status(_ phase: LocalModelStatus.Phase) -> LocalModelStatus {
            LocalModelStatus(phase: phase, model: model, baseURL: baseURL, workloadBaseURL: workloadBaseURL,
                             backend: resolvedBackend, namedBaseURL: namedBaseURL,
                             restarts: restarts, lastCrash: lastCrash)
        }
    }

    struct ProcessIdentity: Codable, Equatable {
        let pid: Int32
        let seconds: UInt64
        let microseconds: UInt64

        static func read(_ pid: Int32) -> Self? {
            guard pid > 0 else { return nil }
            var info = proc_bsdinfo()
            let bytes = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, bytes) == bytes else { return nil }
            return Self(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
        }

        var isLive: Bool { Self.read(pid) == self }
    }

}
