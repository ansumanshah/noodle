import AppKit
import Foundation
import NoodleCore
import Testing
@testable import NoodleApp

@MainActor @Suite struct ModelChatAttachmentTests {
    private func png(width: Int, height: Int) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill(); return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func pixels(_ jpeg: Data) throws -> (Int, Int) {
        let rep = try #require(NSBitmapImageRep(data: jpeg))
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    private func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("noodle-attachment-tests.\(UUID())")
    }

    @Test func downscaleBoundsLongSideAndNeverUpscales() throws {
        let largeJPEG = try #require(ModelChatAttachments.downscaledJPEG(try png(width: 3000, height: 1500)))
        let large = try pixels(largeJPEG)
        #expect(large.0 == 1024 && large.1 == 512)
        let smallJPEG = try #require(ModelChatAttachments.downscaledJPEG(try png(width: 300, height: 200)))
        let small = try pixels(smallJPEG)
        #expect(small.0 == 300 && small.1 == 200)
        #expect(ModelChatAttachments.downscaledJPEG(Data("not an image".utf8)) == nil)
    }

    @Test func requestCarriesTextThenImageUrlParts() throws {
        let jpeg = try #require(ModelChatAttachments.downscaledJPEG(try png(width: 64, height: 64)))
        let endpoint = LocalModelEndpoint(model: "local", baseURL: URL(string: "http://127.0.0.1:11345/v1")!, apiKey: "fixture")
        let messages: [LocalModelChat.Message] = [
            .init(role: .assistant, content: "Earlier"),
            .init(role: .user, content: "What is this?", imageURLs: [ModelChatAttachments.dataURL(jpeg)]),
        ]
        let request = try ModelPromptStream.request(messages: messages, to: endpoint)
        let object = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let sent = try #require(object["messages"] as? [[String: Any]])
        #expect(sent[0]["content"] as? String == "Earlier")
        let parts = try #require(sent[1]["content"] as? [[String: Any]])
        #expect(parts.count == 2)
        #expect(parts[0]["type"] as? String == "text" && parts[0]["text"] as? String == "What is this?")
        #expect(parts[1]["type"] as? String == "image_url")
        let url = try #require((parts[1]["image_url"] as? [String: String])?["url"])
        #expect(url.hasPrefix("data:image/jpeg;base64,"))
        #expect(Data(base64Encoded: String(url.dropFirst("data:image/jpeg;base64,".count))) == jpeg)
    }

    @Test func visionCapabilityComesFromModelsList() {
        let list = Data(#"{"data":[{"id":"a","capabilities":["chat","vision"]},{"id":"b","capabilities":["chat"]}]}"#.utf8)
        #expect(ModelChatAttachments.supportsImages(modelsJSON: list, model: "a"))
        #expect(!ModelChatAttachments.supportsImages(modelsJSON: list, model: "b"))
        #expect(!ModelChatAttachments.supportsImages(modelsJSON: list, model: "missing"))
        #expect(!ModelChatAttachments.supportsImages(modelsJSON: Data("{}".utf8), model: "a"))
    }

    @Test func attachmentsPersistAsFilesAndDeleteWithTheChat() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let history = ModelChatHistory(home: home)
        let jpeg = try #require(ModelChatAttachments.downscaledJPEG(try png(width: 80, height: 80)))
        let names = history.saveAttachments([jpeg, jpeg])
        #expect(names.count == 2)
        let id = history.appendUser("Look", modelID: "local", attachments: names)
        history.flush()
        let folder = ModelChatAttachments.directory(home: home)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
        let saved = try String(contentsOf: home.appendingPathComponent("models/chat-history.json"), encoding: .utf8)
        #expect(!saved.contains("base64") && saved.contains(names[0]))
        let restored = ModelChatHistory(home: home)
        #expect(restored.current?.messages.first?.attachments == names)
        #expect(restored.attachmentData(names) == [jpeg, jpeg])
        restored.delete(id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func deletingOneMessageKeepsOtherChatsImagesAndNamesAreValidated() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let history = ModelChatHistory(home: home)
        let jpeg = try #require(ModelChatAttachments.downscaledJPEG(try png(width: 40, height: 40)))
        let first = history.saveAttachments([jpeg])
        let chatID = history.appendUser("one", modelID: "local", attachments: first)
        history.appendAssistant("ok", state: .completed, conversationID: chatID)
        let second = history.saveAttachments([jpeg])
        history.appendUser("two", modelID: "local", attachments: second)
        history.deleteMessage(try #require(history.current?.messages.first?.id), in: chatID)
        #expect(history.attachmentData(first).isEmpty)
        #expect(history.attachmentData(second) == [jpeg])
        #expect(ModelChatAttachments.load("../chat-history.json", home: home) == nil)
        #expect(!ModelChatAttachments.isValid("../x.jpg"))
    }
}
