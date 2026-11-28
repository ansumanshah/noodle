import Foundation
import Observation

struct ScanReport: Decodable, Sendable {
    struct Match: Decodable, Identifiable, Sendable {
        struct Artifact: Decodable, Sendable { let name: String; let version: String? }
        struct Vulnerability: Decodable, Sendable {
            struct Fix: Decodable, Sendable { let versions: [String]? }
            let id: String
            let severity: String
            let fix: Fix?
        }
        // A package can match the same CVE in multiple locations. Each occurrence gets a stable row identity.
        var id = UUID()
        let artifact: Artifact
        let vulnerability: Vulnerability
        enum CodingKeys: String, CodingKey { case artifact, vulnerability }
    }
    let matches: [Match]
    static let severities = ["Critical", "High", "Medium", "Low", "Negligible", "Unknown"]
    /// 0 is the most severe. A severity the scanner adds later sorts last.
    static func rank(_ severity: String) -> Int {
        severities.firstIndex { $0.caseInsensitiveCompare(severity) == .orderedSame } ?? severities.count
    }
    /// Most severe first, then by vulnerability ID.
    var sorted: [Match] {
        matches.sorted {
            let (a, b) = (Self.rank($0.vulnerability.severity), Self.rank($1.vulnerability.severity))
            return a != b ? a < b : $0.vulnerability.id < $1.vulnerability.id
        }
    }
    func count(_ severity: String) -> Int {
        matches.filter { $0.vulnerability.severity.caseInsensitiveCompare(severity) == .orderedSame }.count
    }
}

struct ScanHistoryEntry: Decodable, Identifiable, Sendable {
    let image: String
    let imageID: String
    let created: String
    let scanner: String
    let version: String
    let result: ScanReport
    var id = UUID()
    enum CodingKeys: String, CodingKey { case image, imageID, created, scanner, version, result }
}

struct ImageSBOM: Decodable, Sendable {
    struct Component: Decodable, Identifiable, Sendable {
        var id = UUID()
        let name: String
        let version: String?
        let type: String?
        let purl: String?
        enum CodingKeys: String, CodingKey { case name, version, type, purl }
    }
    let bomFormat: String
    let components: [Component]
}

@MainActor @Observable
final class SecurityStore {
    struct SBOMResult {
        let imageID: String
        let document: ImageSBOM
        let data: Data
    }

    private(set) var sbom: SBOMResult?
    private(set) var historyVersion = 0
    private(set) var operationImageID: String?
    private(set) var busy = false
    private var error: String?
    private(set) var notice: String?
    private(set) var scanApproved = false
    private(set) var sbomApproved = false

    /// Scan output can be large, so parsing runs on a detached task, not the main actor.
    static func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        try await Task.detached { try JSONDecoder().decode(T.self, from: data) }.value
    }

    static func history(for imageID: String, demo: Bool) async throws -> [ScanHistoryEntry] {
        let data = demo ? SecurityBuildDemo.history : try await CLI.captured(["scan", "--history", imageID])
        let entries = try await decode([ScanHistoryEntry].self, from: data)
        // An image tag can move. The saved image ID is the identity of the scan.
        return entries.filter { $0.imageID == imageID }.sorted { $0.created > $1.created }
    }

    func error(for imageID: String) -> String? {
        operationImageID == nil || operationImageID == imageID ? error : nil
    }

    func scan(imageID: String, demo: Bool) async {
        guard !busy else { return }
        operationImageID = imageID
        scanApproved = true
        busy = true
        error = nil
        notice = nil
        defer { busy = false }
        do {
            if !demo { _ = try await CLI.captured(["scan", imageID, "--json"], timeout: 1200) }
            historyVersion += 1
        } catch { self.error = error.localizedDescription }
    }

    func generateSBOM(imageID: String, demo: Bool) async {
        guard !busy else { return }
        operationImageID = imageID
        sbomApproved = true
        busy = true
        error = nil
        defer { busy = false }
        do {
            let data = demo ? SecurityBuildDemo.sbom : try await CLI.captured(["sbom", imageID], timeout: 1200)
            let decoded = try await Self.decode(ImageSBOM.self, from: data)
            guard decoded.bomFormat == "CycloneDX" else { throw CLI.CommandError.failed("Expected a CycloneDX SBOM.") }
            sbom = SBOMResult(imageID: imageID, document: decoded, data: data)
        } catch { self.error = error.localizedDescription }
    }

    func clearCache(demo: Bool) async {
        guard !busy else { return }
        operationImageID = nil
        busy = true
        error = nil
        defer { busy = false }
        do {
            if !demo { _ = try await CLI.captured(["scan", "--clear-cache"]) }
            scanApproved = false
            notice = "Scan cache cleared. Scan history is kept. The next scan will download the database again."
        } catch { self.error = error.localizedDescription }
    }
}
