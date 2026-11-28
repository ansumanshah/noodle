import Foundation
import Observation
import AppKit

@MainActor @Observable
final class LogsModel {
    private(set) var visible: [LogEntry] = []
    private(set) var total = 0
    private(set) var streaming = false
    private(set) var failure: String?
    var query = "" { didSet { scheduleRefilter() } }
    var minLevel: LogLevel? = nil { didSet { refilter() } }
    var follow = true
    private var merged = false

    private var all: [LogEntry] = []
    private var pending: [LogEntry] = []
    private var nextID = 0
    private var cachedQuery = ""
    private let cap = 5_000

    func clear() { all = []; pending = []; refilter() }

    /// One container's log, or a project's containers merged (each line then starts with its service name).
    func run(sources: [(id: String, label: String?)], service: any DockerService) async {
        merged = sources.count > 1
        all = []; pending = []; nextID = 0; failure = nil; streaming = false; refilter()
        defer { flushTask?.cancel(); flushTask = nil }
        await withTaskGroup(of: Void.self) { group in
            for source in sources { group.addTask { await self.consume(source.id, label: source.label, service: service) } }
        }
        if !Task.isCancelled { streaming = false }
    }

    private func consume(_ id: String, label: String?, service: any DockerService) async {
        let tty = (try? await service.inspect(id).config?.tty) ?? false
        guard !Task.isCancelled else { return }
        do {
            let stream = try await service.logs(id, tty: tty, tail: 400)
            guard !Task.isCancelled else { return }
            streaming = true
            for try await var e in stream {
                guard !Task.isCancelled else { return }
                e.id = nextID; nextID += 1
                if e.text.utf8.count > Self.maxLineBytes { e.text = String(decoding: e.text.utf8.prefix(Self.maxLineBytes), as: UTF8.self) + "…" }
                if let label { e.text = label + " | " + e.text }
                pending.append(e)
                scheduleFlush()
            }
            flush()
        } catch is CancellationError {
        } catch { if !Task.isCancelled, failure == nil { failure = error.localizedDescription } }
    }

    private static let maxLineBytes = 64 * 1024
    private var flushTask: Task<Void, Never>?

    /// One flush per 120 ms window, started by the first pending line. Nothing runs while no output arrives.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.flushTask = nil
            self?.flush()
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let lastBatch = pending.count
        all.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        // Merged streams arrive in any order: keep the whole buffer in time order (ties keep arrival order).
        if merged { all.sort { ($0.time ?? .distantPast, $0.id) < ($1.time ?? .distantPast, $1.id) } }
        if all.count > cap {
            all.removeFirst(all.count - cap)
            refilter()
        } else if merged {
            refilter()
        } else {
            // Streaming path: only the new lines are matched, not the whole buffer.
            total = all.count
            visible.append(contentsOf: all.suffix(lastBatch).filter(matches))
        }
    }

    private var filterTask: Task<Void, Never>?

    /// Typing refilters once per 150 ms pause, so a 5,000-line buffer is not rescanned on every key.
    private func scheduleRefilter() {
        filterTask?.cancel()
        filterTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.refilter()
        }
    }

    private func matches(_ e: LogEntry) -> Bool {
        guard minLevel.map({ e.level >= $0 }) ?? true else { return false }
        return cachedQuery.isEmpty || e.text.range(of: cachedQuery, options: .caseInsensitive) != nil
    }

    /// Applies the current query at once; the debounce calls this, and so do tests.
    func refilter() {
        filterTask?.cancel()
        cachedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        total = all.count
        visible = all.filter(matches)
    }

    /// Adds lines directly (tests and preloaded output); the stream path batches through `pending`.
    func append(_ entries: [LogEntry]) { pending.append(contentsOf: entries); flush() }

    /// What "Copy All" puts on the pasteboard: the lines passing the current text and level filters.
    var plainText: String { visible.map(\.text).joined(separator: "\n") }
}
