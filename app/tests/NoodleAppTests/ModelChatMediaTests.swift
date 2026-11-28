import AVFoundation
import AppKit
import Foundation
import NoodleCore
import Testing
@testable import NoodleApp

@MainActor @Suite struct ModelChatMediaTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-media-tests.\(UUID())")

    init() throws { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

    /// A solid-colour movie of `seconds` at 2 fps, `width` x `height`.
    private func movie(seconds: Int, width: Int = 1280, height: Int = 720) async throws -> URL {
        let url = folder.appendingPathComponent("clip.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 2) {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 20 % 255), CVPixelBufferGetBytesPerRow(pixels) * height)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 2))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return url
    }

    /// A 440 Hz tone as a CAF file at `rate` Hz with `channels` channels.
    private func tone(seconds: Double, rate: Double = 44_100, channels: AVAudioChannelCount = 2) throws -> URL {
        let url = folder.appendingPathComponent("tone.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for index in 0..<Int(frames) { buffer.floatChannelData![channel][index] = sinf(Float(index) * 440 * 2 * .pi / Float(rate)) * 0.3 }
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    private func parts(_ message: LocalModelChat.Message) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(message)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["content"] as? [[String: Any]])
    }

    // MARK: Encoding

    @Test func requestCarriesVideoFramesAndInputAudioParts() throws {
        let frames = ["data:image/jpeg;base64,AAAA", "data:image/jpeg;base64,BBBB"]
        let sent = try parts(.init(role: .user, content: "Describe", videos: [.init(frames: frames, fps: 1.5)],
                                   audios: [.init(base64: "UklGRg==")]))
        #expect(sent.map { $0["type"] as? String } == ["text", "video_url", "input_audio"])
        let video = try #require(sent[1]["video_url"] as? [String: Any])
        #expect(video["frames"] as? [String] == frames && video["fps"] as? Double == 1.5)
        let audio = try #require(sent[2]["input_audio"] as? [String: String])
        #expect(audio == ["data": "UklGRg==", "format": "wav"])
    }

    @Test func mediaOnlyMessageHasNoEmptyTextPartAndTextOnlyStaysAString() throws {
        #expect(try parts(.init(role: .user, content: "", imageURLs: ["data:image/jpeg;base64,AA"])).map { $0["type"] as? String } == ["image_url"])
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalModelChat.Message(role: .user, content: "hi"))) as? [String: Any]
        #expect(plain?["content"] as? String == "hi")
    }

    // MARK: Video

    @Test func sampleTimesAreAboutOnePerSecondCappedAndInsideTheClip() {
        #expect(ModelChatMedia.sampleTimes(duration: 0) == [0])
        #expect(ModelChatMedia.sampleTimes(duration: 0.2).count == 1)
        #expect(ModelChatMedia.sampleTimes(duration: 10).count == 10)
        let long = ModelChatMedia.sampleTimes(duration: 600)
        #expect(long.count == ModelChatMedia.maximumFrames)
        #expect(long == long.sorted() && long.first! > 0 && long.last! < 600)
    }

    @Test func videoClipSamplesDownscaledFrames() async throws {
        let clip = try await ModelChatMedia.videoClip(from: try await movie(seconds: 3))
        #expect(clip.frames.count == 3)
        #expect(abs(clip.duration - 3) < 0.6)
        let rep = try #require(NSBitmapImageRep(data: clip.frames[0]))
        #expect(max(rep.pixelsWide, rep.pixelsHigh) == ModelChatMedia.frameLongSide && rep.pixelsWide > rep.pixelsHigh)
        #expect(clip.message.frames.allSatisfy { $0.hasPrefix("data:image/jpeg;base64,") } && clip.message.fps != nil)
    }

    @Test func audioFileIsNotAVideo() async throws {
        await #expect(throws: (any Error).self) { _ = try await ModelChatMedia.videoClip(from: try self.tone(seconds: 1)) }
    }

    // MARK: Audio

    @Test func audioConvertsToSixteenKilohertzMonoWav() throws {
        let wav = try ModelChatMedia.wav(from: try tone(seconds: 2))
        #expect(wav.prefix(4) == Data("RIFF".utf8) && wav[8..<12] == Data("WAVE".utf8))
        func u16(_ at: Int) -> Int { Int(wav[at]) | Int(wav[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        #expect(u16(20) == 1 && u16(22) == 1 && u32(24) == 16_000 && u16(34) == 16)
        #expect(u32(40) == wav.count - 44)
        #expect(abs(ModelChatMedia.wavDuration(wav) - 2) < 0.05)
        let peak = wav.dropFirst(44).withUnsafeBytes { $0.bindMemory(to: Int16.self).map { abs(Int($0)) }.max() ?? 0 }
        #expect(peak > 5_000, "the tone survives conversion")
    }

    @Test func audioLongerThanFiveMinutesIsRefused() throws {
        let url = try tone(seconds: ModelChatMedia.maximumAudioSeconds + 5, rate: 8_000, channels: 1)
        #expect(throws: (any Error).self) { try ModelChatMedia.wav(from: url) }
    }

    // MARK: Capability

    @Test func capabilityComesFromInputModalitiesPerModel() {
        let list = Data(#"""
        {"data":[{"id":"a","capabilities":["chat","vision"],"input_modalities":["text","image","video"]},
                 {"id":"b","capabilities":["chat"],"input_modalities":["text","audio"]},
                 {"id":"c","capabilities":["chat","vision"]}]}
        """#.utf8)
        #expect(ModelChatMedia.support(modelsJSON: list, model: "a") == .init(images: true, video: true, audio: false))
        #expect(ModelChatMedia.support(modelsJSON: list, model: "b") == .init(images: false, video: false, audio: true))
        #expect(ModelChatMedia.support(modelsJSON: list, model: "c") == .init(images: true, video: false, audio: false))
        #expect(ModelChatMedia.support(modelsJSON: list, model: "missing") == .init())
        #expect(ModelChatMedia.support(modelsJSON: Data("{}".utf8), model: "a") == .init())
    }

    @Test func attachmentsMakeAnEmptyMessageSendable() {
        #expect(!ModelComposerState.ready.canSend(""))
        #expect(ModelComposerState.ready.canSend("", hasAttachments: true))
        #expect(!ModelComposerState.busy.canSend("", hasAttachments: true))
    }

    // MARK: Store

    private func store() -> ModelsPageStore { ModelsPageStore(demo: false, chatHistory: ModelChatHistory(home: folder)) }

    private var clip: ModelAudioClip { ModelAudioClip(wav: ModelChatMedia.wavHeader(byteCount: 64_000) + Data(count: 64_000), name: "memo.m4a") }

    @Test func modelWithoutAudioGetsTheTranscriptAndANote() async throws {
        let store = store()
        var sent: [LocalModelChat.Message] = []
        await store.runPrompt("Summarise", modelID: "m", attachments: .init(audio: clip),
                              transcribe: { _ in "hello from the clip" }) { messages, emit, _ in sent = messages; emit("ok") }
        let content = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try #require(sent.last))) as? [String: Any]
        let text = try #require(content?["content"] as? String, "audio is replaced, so the content is plain text")
        #expect(text == "Summarise\n\n[Transcribed from memo.m4a]\nhello from the clip")
    }

    @Test func modelThatHearsGetsInputAudioAndFailedTranscriptionIsReported() async throws {
        let store = store()
        var sent: [LocalModelChat.Message] = []
        await store.runPrompt("", modelID: "m", attachments: .init(audio: clip)) { messages, emit, _ in sent = messages; emit("ok") }
        #expect(try parts(try #require(sent.last)).map { $0["type"] as? String } == ["input_audio"])
        await store.runPrompt("again", modelID: "m", attachments: .init(audio: clip), transcribe: { _ in throw ModelPromptError("no asr") }) { _, _, _ in }
        #expect(store.chat.current?.messages.last?.state == .failed || store.problem != nil)
    }

    @Test func imageOnlyMessageSendsAndIsStored() async throws {
        let store = store()
        var count = 0
        await store.runPrompt("", modelID: "m", attachments: .init(images: [Data([1, 2, 3])])) { messages, emit, _ in count = messages.count; emit("seen") }
        #expect(count == 1 && store.chat.current?.messages.count == 2)
    }

    // MARK: Persistence

    @Test func videoAndAudioPersistAsFilesRestoreAndDeleteWithTheChat() throws {
        let history = ModelChatHistory(home: folder)
        let video = ModelVideoClip(duration: 2, frames: [Data([9, 9]), Data([8])])
        let names = history.saveAttachments(.init(images: [Data([1])], video: video, audio: clip))
        #expect(names.count == 3 && names.allSatisfy(ModelChatAttachments.isValid))
        #expect(names.map { String($0.split(separator: ".").last!) } == ["jpg", "vid", "wav"])
        let id = history.appendUser("look", modelID: "m", attachments: names)
        history.flush()
        let saved = try String(contentsOf: folder.appendingPathComponent("models/chat-history.json"), encoding: .utf8)
        #expect(!saved.contains("base64") && saved.contains(names[1]), "history keeps references only")
        let restored = ModelChatHistory(home: folder).attachmentSet(names)
        #expect(restored.images == [Data([1])] && restored.video == video && restored.audio?.wav == clip.wav)
        history.delete(id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: ModelChatAttachments.directory(home: folder).path).isEmpty)
        #expect(!ModelChatAttachments.isValid("../x.wav") && !ModelChatAttachments.isValid("\(UUID()).mov"))
    }
}
