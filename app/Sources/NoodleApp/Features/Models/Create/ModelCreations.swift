import Foundation
import Observation

struct ModelCreation: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: ModelCreateKind
    let prompt: String
    let model: String
    /// File name inside the creations folder, never a path.
    let file: String
    let created: Date
}

/// Everything Create made, kept in `<home>/models/creations/` with an `index.json` listing newest first.
@MainActor @Observable
final class ModelCreations {
    private(set) var items: [ModelCreation] = []
    let folder: URL

    init(folder: URL) {
        self.folder = folder
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder.creations.decode([ModelCreation].self, from: data) else { return }
        // A file removed outside Noodle drops out of the list.
        items = saved.filter { Self.safe($0.file) && FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.file).path) }
    }

    convenience init(home: URL) {
        self.init(folder: home.appendingPathComponent("models/creations", isDirectory: true))
    }

    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    func url(for creation: ModelCreation) -> URL { folder.appendingPathComponent(creation.file) }

    /// A fresh file in the folder for `kind`, which the caller fills before `record`.
    func newFile(_ ext: String) throws -> (UUID, URL) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID()
        return (id, folder.appendingPathComponent("\(id.uuidString.lowercased()).\(ext)"))
    }

    @discardableResult
    func record(id: UUID, file: URL, kind: ModelCreateKind, prompt: String, model: String) throws -> ModelCreation {
        let creation = ModelCreation(id: id, kind: kind, prompt: prompt, model: model, file: file.lastPathComponent, created: .now)
        items.insert(creation, at: 0)
        try save()
        return creation
    }

    @discardableResult
    func add(_ data: Data, ext: String, kind: ModelCreateKind, prompt: String, model: String) throws -> ModelCreation {
        let (id, url) = try newFile(ext)
        try data.write(to: url, options: .atomic)
        return try record(id: id, file: url, kind: kind, prompt: prompt, model: model)
    }

    func delete(_ id: UUID) throws {
        guard let creation = items.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: url(for: creation))
        items.removeAll { $0.id == id }
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder.creations.encode(items).write(to: indexURL, options: .atomic)
    }

    private static func safe(_ file: String) -> Bool { !file.isEmpty && !file.contains("/") && !file.hasPrefix(".") }
}

private extension JSONEncoder {
    static var creations: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var creations: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
