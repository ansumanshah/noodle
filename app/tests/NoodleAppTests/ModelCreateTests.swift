import AVFoundation
import Foundation
import NoodleCore
import Testing
@testable import NoodleApp

@Suite struct ModelCreateRequestTests {
    private func json(_ body: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func imageBodyCarriesSizeStepsAndSeed() throws {
        var options = ModelCreateOptions()
        options.size = "768x768"; options.steps = 6; options.seed = 42
        let body = try json(ModelCreateRequest.body(kind: .image, model: "hf.co/org/flux", prompt: "boat", options: options))
        #expect(body["model"] as? String == "org/flux" && body["prompt"] as? String == "boat")
        #expect(body["size"] as? String == "768x768" && body["steps"] as? Int == 6 && body["seed"] as? Int == 42)
        #expect(body["stream"] as? Bool == true && body["image"] == nil)
    }

    @Test func imageEditSendsThePictureAndKeepsItsSize() throws {
        let body = try json(ModelCreateRequest.body(kind: .image, model: "flux", prompt: "make it night", options: .init(),
                                                    editImage: Data([1, 2, 3])))
        #expect(body["image"] as? String == "AQID" && body["mode"] as? String == "edit" && body["size"] == nil && body["seed"] == nil)
    }

    @Test func speechAndVideoBodies() throws {
        var options = ModelCreateOptions()
        options.voice = "bm_george"; options.frames = 97
        let speech = try json(ModelCreateRequest.body(kind: .speech, model: "kokoro-82m", prompt: "Hello", options: options))
        #expect(speech["input"] as? String == "Hello" && speech["voice"] as? String == "bm_george" && speech["prompt"] == nil)
        let video = try json(ModelCreateRequest.body(kind: .video, model: "ltx", prompt: "rain", options: options))
        #expect(video["num_frames"] as? Int == 97 && video["width"] as? Int == 768 && video["height"] as? Int == 512)
        #expect(video["preview"] as? Bool == true && video["steps"] as? Int == 8)
    }

    @Test func requestGoesToTheKindsEndpointWithTheKey() throws {
        let endpoint = try JSONDecoder().decode(LocalModelEndpoint.self, from: Data(
            #"{"model":"m","baseURL":"http://127.0.0.1:9/v1","apiKey":"k"}"#.utf8))
        let request = try ModelCreateRequest.urlRequest(kind: .video, body: ["a": 1], endpoint: endpoint)
        #expect(request.url?.absoluteString == "http://127.0.0.1:9/v1/video/generations")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k" && request.httpMethod == "POST")
    }
}

@Suite struct ModelCreateStreamTests {
    @Test func keepalivesAndBlanksAreSkipped() throws {
        #expect(try ModelCreateStream.parse(": keepalive") == nil)
        #expect(try ModelCreateStream.parse("") == nil)
        #expect(try ModelCreateStream.parse("data: [DONE]") == nil)
    }

    @Test func progressCarriesStepsAndPreview() throws {
        let event = try ModelCreateStream.parse(#"data: {"type":"progress","stage":"denoise","step":2,"total":4,"preview":"/9g=","mime":"image/jpeg"}"#)
        #expect(event == .progress(stage: "denoise", step: 2, total: 4, preview: Data([0xFF, 0xD8])))
    }

    @Test func completeImageSpeechAndError() throws {
        #expect(try ModelCreateStream.parse(#"data: {"type":"complete","data":[{"b64_json":"iVBO"}]}"#) == .complete(.image(Data([0x89, 0x50, 0x4E]))))
        #expect(try ModelCreateStream.parse(#"data: {"type":"complete","format":"wav","data":"UklG"}"#) == .complete(.audio(Data("RIF".utf8))))
        #expect(try ModelCreateStream.parse(#"data: {"type":"error","message":"boom"}"#) == .failed("boom"))
        #expect(throws: (any Error).self) { try ModelCreateStream.parse(#"data: {"type":"complete","data":[{}]}"#) }
    }

    @Test func videoFramesAreCheckedAgainstTheirSize() throws {
        let rgb = Data(repeating: 7, count: 2 * 2 * 3 * 2).base64EncodedString()
        let line = #"data: {"type":"complete","format":"rgb8","frames":2,"width":2,"height":2,"data":"\#(rgb)","audio_format":"pcm_s16le","audio_data":"AAAAAA==","audio_sample_rate":24000}"#
        guard case .complete(.frames(let frames)) = try ModelCreateStream.parse(line) else { Issue.record("no frames"); return }
        #expect(frames.count == 2 && frames.fps == 24 && frames.sampleRate == 24000 && frames.channels == 2 && frames.pcm?.count == 4)
        #expect(throws: (any Error).self) { try ModelCreateStream.parse(line.replacingOccurrences(of: #""frames":2"#, with: #""frames":3"#)) }
    }
}

@Suite struct ModelCreateMuxTests {
    @Test func rgbFramesAndPCMBecomeAPlayableMP4() async throws {
        let width = 64, height = 48, count = 12, rate = 16_000
        var rgb = Data(count: width * height * 3 * count)
        for index in 0..<rgb.count { rgb[index] = UInt8(index % 251) }
        let pcm = Data((0..<(rate / 2 * 2)).flatMap { sample -> [UInt8] in
            let value = Int16(sin(Double(sample / 2) / 10) * 8_000)
            return [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
        })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mux-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ModelCreateMux.write(ModelCreateFrames(rgb: rgb, width: width, height: height, count: count, fps: 24,
                                                         pcm: pcm, sampleRate: rate, channels: 2), to: url)
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(video.count == 1 && audio.count == 1)
        let size = try await video[0].load(.naturalSize)
        #expect(Int(size.width) == width && Int(size.height) == height)
        let seconds = try await asset.load(.duration).seconds
        #expect(seconds > 0.4 && seconds < 0.7, "\(seconds)")
    }
}

@MainActor @Suite struct ModelCreationsTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("creations-\(UUID().uuidString)") }

    @Test func indexSurvivesReloadAndDeleteRemovesTheFile() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModelCreations(folder: dir)
        let first = try store.add(Data([1]), ext: "png", kind: .image, prompt: "a", model: "flux")
        let second = try store.add(Data([2]), ext: "wav", kind: .speech, prompt: "b", model: "kokoro-82m")
        let reloaded = ModelCreations(folder: dir)
        #expect(reloaded.items.map(\.id) == [second.id, first.id] && reloaded.items[1].kind == .image)
        try reloaded.delete(first.id)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(first.file).path))
        #expect(ModelCreations(folder: dir).items.map(\.id) == [second.id])
    }

    @Test func filesRemovedOutsideNoodleDropOut() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModelCreations(folder: dir)
        let item = try store.add(Data([1]), ext: "png", kind: .image, prompt: "a", model: "flux")
        try FileManager.default.removeItem(at: store.url(for: item))
        #expect(ModelCreations(folder: dir).items.isEmpty)
    }

    @Test func homeLayoutIsModelsCreations() {
        let home = URL(fileURLWithPath: "/tmp/home")
        #expect(ModelCreations(home: home).folder.path == "/tmp/home/models/creations")
    }
}
