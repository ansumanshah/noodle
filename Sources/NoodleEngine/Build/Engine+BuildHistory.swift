import Foundation
import NoodleCore

extension Engine {
    func withBuildHistory(context: URL, options: BuildOptions,
                          progress: @escaping @Sendable (String) async throws -> Void,
                          body: (@escaping @Sendable (String) async throws -> Void) async throws -> String) async throws -> String {
        let size = Int64(try context.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let capture = BuildHistoryCapture(tags: options.tags, args: options.args, contextSize: size, root: paths.root)
        try await capture.begin()
        let id: String
        do {
            id = try await body { message in
                await capture.append(message)
                try await progress(message)
            }
        } catch {
            try await capture.finish(error: String(describing: error), cancelled: error is CancellationError || Task.isCancelled)
            throw error
        }
        try await capture.finish(error: nil, cancelled: false)
        return id
    }
}

// Private capability-authenticated snapshots from the transient native helper.
extension Engine {
    public func recordNativeBuildHistory(token: String, data: Data) async throws {
        guard let owner = nativeImportOwner, token == owner.token else {
            throw EngineError.badRequest("invalid build capability")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601.parse(text) else { throw EngineError.badRequest("invalid build timestamp") }
            return date
        }
        var record = try decoder.decode(BuildHistoryRecord.self, from: data)
        guard record.id.count == 32, record.id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              record.tags.count <= 128, record.tags.allSatisfy({ $0.utf8.count <= 1024 }),
              ["running", "success", "failed", "cancelled"].contains(record.status),
              record.cachedSteps >= 0, record.cachedSteps <= record.totalSteps,
              record.totalSteps <= 100_000, record.contextSize >= 0,
              record.log.utf8.count <= 2 << 20, (record.error?.utf8.count ?? 0) <= 4096,
              record.duration.isFinite, record.duration >= 0 else {
            throw EngineError.badRequest("invalid build history record")
        }
        let redactor = Redactor()
        record.tags = record.tags.map { tag in
            redactor.redact((try? BuildOptions(tags: [tag]).tags.first) ?? tag)
        }
        record.error = record.error.map { redactor.redact($0) }
        record.log = redactor.redact(record.log)
        while record.log.utf8.count > 2 << 20 { record.log.removeLast() }
        if record.status == "running" {
            guard owner.buildHistoryRecords[record.id] == nil, record.endedAt == nil,
                  record.log.isEmpty, record.error == nil else {
                throw EngineError.conflict("build history already started")
            }
        } else {
            guard let start = owner.buildHistoryRecords[record.id], let end = record.endedAt,
                  end >= start.startedAt else { throw EngineError.badRequest("build history was not started") }
            record.startedAt = start.startedAt
            record.duration = end.timeIntervalSince(start.startedAt)
        }
        try await BuildHistoryWriter.shared.write(record, root: paths.root)
        if record.status == "running" { owner.buildHistoryRecords[record.id] = record }
        else { owner.buildHistoryRecords.removeValue(forKey: record.id) }
    }

    func finishAbandonedNativeBuilds(_ owner: NativeBuilder) async {
        let pending = owner.buildHistoryRecords
        owner.buildHistoryRecords.removeAll()
        for var record in pending.values {
            record.status = "cancelled"
            record.endedAt = Date()
            record.duration = max(0, record.endedAt!.timeIntervalSince(record.startedAt))
            record.error = "BuildKit stopped before reporting completion"
            try? await BuildHistoryWriter.shared.cancelIfRunning(record, root: paths.root)
        }
    }
}
