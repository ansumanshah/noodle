import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Image attachments for Models chat. Limits: at most `maximumPerMessage` images per message, each downscaled
/// so its long side is at most `longSide` px and re-encoded as JPEG, which keeps a request to a few hundred KB.
/// Saved copies live in `<home>/models/chat-attachments/<uuid>.jpg`; chat history keeps only the file name.
enum ModelChatAttachments {
    static let maximumPerMessage = 4
    static let longSide = 1024
    static let jpegQuality = 0.8
    /// Larger inputs are refused before decoding (a 12 MP photo is ~5 MB; this is generous).
    static let maximumInputBytes = 40_000_000

    /// Long side capped at `longSide` (never upscaled), EXIF orientation applied, alpha flattened onto white.
    static func downscaledJPEG(_ data: Data) -> Data? {
        guard data.count <= maximumInputBytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: longSide,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
            kCGImageDestinationBackgroundColor: CGColor(gray: 1, alpha: 1),
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    static func dataURL(_ jpeg: Data) -> String { "data:image/jpeg;base64," + jpeg.base64EncodedString() }

    /// Image files or raw image data on a pasteboard (paste and drag). Files win over a text caption.
    static func images(in pasteboard: NSPasteboard) -> [Data] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let files = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            .compactMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
        if !files.isEmpty { return files }
        guard urls.isEmpty else { return [] }
        return (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []).compactMap { $0.tiffRepresentation }
    }

    static func hasImages(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSImage.self]) || ((pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL])?.isEmpty == false)
    }

    /// `GET /v1/models` rows carry `capabilities` (mlx-serve), e.g. `["chat","vision"]`. A lone row stands for the running model.
    static func supportsImages(modelsJSON: Data, model: String) -> Bool {
        struct List: Decodable {
            struct Row: Decodable { let id: String?; let capabilities: [String]? }
            let data: [Row]
        }
        guard let rows = try? JSONDecoder().decode(List.self, from: modelsJSON).data else { return false }
        let row = rows.first { $0.id == model } ?? (rows.count == 1 ? rows[0] : nil)
        return row?.capabilities?.contains("vision") == true
    }

    // MARK: Files

    static func directory(home: URL) -> URL {
        home.appendingPathComponent("models", isDirectory: true).appendingPathComponent("chat-attachments", isDirectory: true)
    }

    /// Only names this app wrote (`<uuid>.jpg` image, `<uuid>.vid` video frames as JSON, `<uuid>.wav` audio);
    /// history JSON is untrusted input for paths.
    static func isValid(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), ["jpg", "vid", "wav"].contains(name[name.index(after: dot)...]) else { return false }
        return UUID(uuidString: String(name[..<dot])) != nil
    }

    static func save(_ jpeg: Data, home: URL) throws -> String { try save(jpeg, extension: "jpg", home: home) }

    static func save(_ data: Data, extension ext: String, home: URL) throws -> String {
        let folder = directory(home: home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = UUID().uuidString + "." + ext
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appendingPathComponent(name).path)
        return name
    }

    static func load(_ name: String, home: URL) -> Data? {
        guard isValid(name) else { return nil }
        return try? Data(contentsOf: directory(home: home).appendingPathComponent(name))
    }

    static func remove(_ names: some Sequence<String>, home: URL) {
        for name in names where isValid(name) { try? FileManager.default.removeItem(at: directory(home: home).appendingPathComponent(name)) }
    }
}

/// An image waiting in the composer: already downscaled, with a small thumbnail for display.
struct ModelDraftImage: Identifiable {
    let id = UUID()
    let jpeg: Data
    let thumbnail: NSImage

    init?(_ original: Data) {
        guard let jpeg = ModelChatAttachments.downscaledJPEG(original), let image = NSImage(data: jpeg) else { return nil }
        self.jpeg = jpeg
        thumbnail = image
    }
}
