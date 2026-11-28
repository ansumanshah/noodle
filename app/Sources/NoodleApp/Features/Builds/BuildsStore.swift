import Foundation
import Observation

struct AppBuildRecord: Decodable, Identifiable, Sendable {
    let id: String
    let tags: [String]
    let startedAt: String
    let endedAt: String?
    let status: String
    let error: String?
    let duration: Double
    let cachedSteps: Int
    let totalSteps: Int
    let contextSize: Int64
    let log: String?
    var title: String { tags.isEmpty ? String(id.prefix(12)) : tags.joined(separator: ", ") }
}

@MainActor @Observable
final class BuildsStore {
    private(set) var records: [AppBuildRecord] = []
    var selectedID: String?
    private(set) var detail: AppBuildRecord?
    private(set) var steps: [BuildProgressStep] = []
    private(set) var busy = false
    private(set) var loadingDetail = false
    var error: String?

    func refresh(demo: Bool) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let data = demo ? (DemoFlags.empty ? Data("[]".utf8) : SecurityBuildDemo.builds) : try await CLI.captured(["builds", "list", "--json"])
            records = try JSONDecoder().decode([AppBuildRecord].self, from: data)
            if let selectedID, !records.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
                detail = nil
            }
            if selectedID == nil { selectedID = records.first?.id }
        } catch { self.error = Self.message(error) }
    }

    /// Command failures already say what to do; anything else here is output the app cannot read.
    private static func message(_ error: Error) -> String {
        if error is CLI.CommandError { return error.localizedDescription }
        return String(localized: "Couldn’t read the build history. Update Noodle so the app and command line tool match, then try again.")
    }

    func inspect(demo: Bool) async {
        detail = nil
        steps = []
        guard let id = selectedID else { loadingDetail = false; return }
        loadingDetail = true
        error = nil
        defer { if selectedID == id { loadingDetail = false } }
        do {
            let data = demo ? SecurityBuildDemo.buildDetail(id) : try await CLI.captured(["builds", "inspect", id])
            let record = try JSONDecoder().decode(AppBuildRecord.self, from: data)
            guard !Task.isCancelled, selectedID == id else { return }
            steps = BuildProgressStep.parse(record.log)
            detail = record
        } catch {
            if !Task.isCancelled, selectedID == id { self.error = Self.message(error) }
        }
    }
}

/// A best-effort view of BuildKit's plain progress output. The raw log remains authoritative.
struct BuildProgressStep: Identifiable, Equatable {
    let id: Int
    var title = ""
    var status = "In progress"
    var duration: String?
    var output: [String] = []

    static func parse(_ log: String?) -> [BuildProgressStep] {
        guard let log else { return [] }
        var steps: [BuildProgressStep] = []
        var indexes: [Int: Int] = [:]
        for line in log.components(separatedBy: .newlines) {
            guard line.first == "#", let space = line.firstIndex(of: " "),
                  let id = Int(line[line.index(after: line.startIndex)..<space]) else { continue }
            let message = String(line[line.index(after: space)...])
            let index: Int
            if let existing = indexes[id] { index = existing }
            else { index = steps.count; indexes[id] = index; steps.append(BuildProgressStep(id: id)) }
            steps[index].output.append(line)
            if message.hasPrefix("DONE") {
                steps[index].status = "Done"
                let parts = message.split(separator: " ")
                if parts.count > 1, parts[1].hasSuffix("s") { steps[index].duration = String(parts[1]) }
            } else if message.hasPrefix("CACHED") {
                steps[index].status = "Cached"
            } else if message.hasPrefix("ERROR") {
                steps[index].status = "Failed"
            } else if message.hasPrefix("CANCELED") || message.hasPrefix("CANCELLED") {
                steps[index].status = "Cancelled"
            } else if steps[index].title.isEmpty && !message.isEmpty {
                steps[index].title = message
            }
        }
        return steps
    }
}
