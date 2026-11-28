import Foundation
import Observation
import AppKit

@MainActor @Observable
final class FilesModel {
    enum Preview: Equatable {
        case none, loading
        case text(String, truncated: Bool)
        case binary(Int)
        case directory
        case failed(String)
    }
    private(set) var path = "/"
    private(set) var entries: [FileEntry] = []
    private(set) var loading = true
    private(set) var failure: String?
    private(set) var preview: Preview = .none
    var selection: String? { didSet { if oldValue != selection { previewTask?.cancel(); previewTask = Task { await loadPreview() } } } }
    private(set) var notice: String?
    func clearNotice() { notice = nil }
    func clearFailure() { failure = nil }
    private var containerID = ""
    private var service: (any DockerService)?
    private var previewTask: Task<Void, Never>?
    private var listingRevision = 0

    func open(id: String, service: any DockerService) async {
        containerID = id; self.service = service
        await go("/")
    }

    func go(_ newPath: String) async {
        guard let service else { return }
        listingRevision += 1
        let revision = listingRevision
        loading = true; failure = nil; selection = nil; preview = .none
        let clean = newPath.isEmpty ? "/" : newPath
        do {
            let list = try await service.list(containerID, path: clean)
            try Task.checkCancellation()
            guard revision == listingRevision else { return }
            Motion.animate { path = clean; entries = list }
        } catch is CancellationError {
        } catch {
            guard revision == listingRevision, !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
        guard revision == listingRevision else { return }
        loading = false
    }

    var crumbs: [(name: String, path: String)] {
        var out: [(String, String)] = [("/", "/")]
        var acc = ""
        for part in path.split(separator: "/") { acc += "/" + part; out.append((String(part), acc)) }
        return out
    }

    var selectedEntry: FileEntry? { entries.first { $0.id == selection } }

    /// A tar header plus the preview bytes, with room for a pax header. Reading stops here; the rest is never fetched.
    private static let previewTarBytes = 512 + 256 * 1024 + 2048

    private func loadPreview() async {
        guard let service, let entry = selectedEntry else { preview = .none; return }
        if entry.isDirectory { preview = .directory; return }
        preview = .loading
        do {
            var tar = Data(), capped = false
            for try await chunk in try await service.archiveStream(containerID, path: entry.path) {
                tar.append(chunk)
                if tar.count >= Self.previewTarBytes { capped = true; break }
            }
            if Task.isCancelled { return }
            guard let file = Tar.entries(tar, maxEntries: 4).first(where: { !$0.isDirectory }) else { preview = .binary(0); return }
            let head = file.data.prefix(256 * 1024)
            if !head.contains(0), let s = String(data: head, encoding: .utf8) {
                preview = .text(s, truncated: capped || file.data.count > head.count)
            } else {
                preview = .binary(file.size)
            }
        } catch is CancellationError {
        } catch { preview = .failed(error.localizedDescription) }
    }

    /// Saves the entry to ~/Downloads (files extracted, folders as .tar) and returns the URL.
    @discardableResult
    func saveToDownloads(_ entry: FileEntry) async -> URL? {
        guard let service else { return nil }
        do {
            let stream = try await service.archiveStream(containerID, path: entry.path)
            let target = try await Self.save(stream, entry: entry)
            notice = "Saved to Downloads as \(target.lastPathComponent)"
            return target
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    /// Runs off the main actor. The tar goes to a temp file chunk by chunk; the result is renamed into Downloads.
    nonisolated private static func save(_ stream: AsyncThrowingStream<Data, Error>, entry: FileEntry) async throws -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        guard DockerAPI.isSafeName(entry.name) else { throw HTTPFailure(status: 0, message: String(localized: "Unsafe file name")) }
        let spool = fm.temporaryDirectory.appendingPathComponent("noodle-files-\(UUID().uuidString).tar")
        let part = dir.appendingPathComponent(".noodle-\(UUID().uuidString).part")
        defer { try? fm.removeItem(at: spool); try? fm.removeItem(at: part) }
        fm.createFile(atPath: spool.path, contents: nil)
        let out = try FileHandle(forWritingTo: spool)
        do {
            for try await chunk in stream { try out.write(contentsOf: chunk) }
            try out.close()
        } catch { try? out.close(); throw error }
        let name: String
        if entry.isDirectory {
            name = entry.name + ".tar"
            try fm.moveItem(at: spool, to: part)
        } else {
            let tar = try Data(contentsOf: spool, options: .alwaysMapped)
            guard let file = Tar.entries(tar, maxEntries: 4, keepData: false).first(where: { !$0.isDirectory }) else {
                throw HTTPFailure(status: 0, message: String(localized: "Nothing to save"))
            }
            guard file.complete else { throw HTTPFailure(status: 0, message: String(localized: "The file ended early; nothing was saved")) }
            let parts = file.name.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.name.hasPrefix("/"), !parts.contains("..") else { throw HTTPFailure(status: 0, message: String(localized: "Unsafe path in archive")) }
            name = entry.name
            try tar[file.offset..<file.offset + file.size].write(to: part)
        }
        let target = unique(dir.appendingPathComponent(name))
        let root = dir.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard target.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path + "/" == root else {
            throw HTTPFailure(status: 0, message: String(localized: "Refusing to save outside Downloads"))
        }
        try quarantine(part)   // before the move: on failure nothing unflagged lands in Downloads
        try fm.moveItem(at: part, to: target)
        return target
    }

    /// Container content is untrusted: Gatekeeper asks before anything saved from it runs, as for a browser download.
    /// Folders are saved as one .tar file, so the flag carries to whatever Archive Utility extracts from it.
    nonisolated static func quarantine(_ url: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Noodle",
                                       kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
        var url = url
        try url.setResourceValues(values)
    }

    func showInFinder(_ entry: FileEntry) async {
        if let url = await saveToDownloads(entry) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    nonisolated private static func unique(_ url: URL) -> URL {
        var candidate = url
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = url.deletingPathExtension().lastPathComponent
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n)").appendingPathExtension(url.pathExtension)
            n += 1
        }
        return candidate
    }
}
