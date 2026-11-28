import Foundation

/// What a finished job hands back, decoded from the `complete` event.
enum ModelCreateOutput: Equatable, Sendable {
    case image(Data)
    case audio(Data)
    /// Raw rgb8 frames, plus interleaved s16le audio when the model made sound.
    case frames(ModelCreateFrames)
}

struct ModelCreateFrames: Equatable, Sendable {
    let rgb: Data
    let width: Int
    let height: Int
    let count: Int
    let fps: Int
    var pcm: Data?
    var sampleRate = 16_000
    var channels = 2
}

enum ModelCreateEvent: Equatable, Sendable {
    case progress(stage: String?, step: Int?, total: Int?, preview: Data?)
    case complete(ModelCreateOutput)
    case failed(String)
}

enum ModelCreateStream {
    /// One SSE line. Comments (`: keepalive`), blank lines and `[DONE]` give nil.
    static func parse(_ line: String) throws -> ModelCreateEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let event = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw ModelPromptError("The model sent a reply Noodle could not read.")
        }
        switch event["type"] as? String {
        case "progress":
            return .progress(stage: event["stage"] as? String, step: event["step"] as? Int, total: event["total"] as? Int,
                             preview: (event["preview"] as? String).flatMap { Data(base64Encoded: $0) })
        case "error":
            return .failed(event["message"] as? String ?? String(localized: "The model stopped with an error."))
        case "complete":
            return .complete(try output(event))
        default:
            return nil
        }
    }

    private static func output(_ event: [String: Any]) throws -> ModelCreateOutput {
        func bytes(_ value: Any?) throws -> Data {
            guard let text = value as? String, let data = Data(base64Encoded: text), !data.isEmpty else {
                throw ModelPromptError("The model finished without a result.")
            }
            return data
        }
        if let images = event["data"] as? [[String: Any]] { return .image(try bytes(images.first?["b64_json"])) }
        guard event["format"] as? String == "rgb8" else { return .audio(try bytes(event["data"])) }
        let width = event["width"] as? Int ?? 0, height = event["height"] as? Int ?? 0, count = event["frames"] as? Int ?? 0
        let rgb = try bytes(event["data"])
        guard width > 0, height > 0, count > 0, rgb.count == width * height * 3 * count else {
            throw ModelPromptError("The video frames arrived incomplete.")
        }
        var frames = ModelCreateFrames(rgb: rgb, width: width, height: height, count: count, fps: event["fps"] as? Int ?? 24)
        if event["audio_format"] as? String == "pcm_s16le", let pcm = try? bytes(event["audio_data"]) {
            frames.pcm = pcm
            frames.sampleRate = event["audio_sample_rate"] as? Int ?? 16_000
            frames.channels = event["audio_channels"] as? Int ?? 2
        }
        return .frames(frames)
    }

    /// Sends the job and reports each event until `complete`. A memory refusal throws `ModelMemoryRefusal`.
    @MainActor
    static func run(_ request: URLRequest, onEvent: @MainActor (ModelCreateEvent) -> Void) async throws -> ModelCreateOutput {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForResource = 3_600
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                var body: [UInt8] = []
                for try await byte in bytes { body.append(byte); if body.count >= 4096 { break } }
                let text = String(decoding: body, as: UTF8.self)
                // mlx-serve 26.11.3 tags a memory refusal with `"reason":"memory_refused"`; the text match covers older runtimes.
                if text.contains(#""reason":"memory_refused""#) || ModelMemoryRefusal.matches(status: status, body: text) {
                    throw ModelMemoryRefusal()
                }
                throw ModelPromptError("The model could not make this (\(status)). Check the model and try again.")
            }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let event = try parse(line) else { continue }
                switch event {
                case .complete(let output): return output
                case .failed(let message):
                    if ModelMemoryRefusal.matchesMidStream(message) { throw ModelMemoryRefusal() }
                    throw ModelPromptError(message)
                case .progress: onEvent(event)
                }
            }
            throw ModelPromptError("The model stopped before it finished.")
        } onCancel: {
            session.invalidateAndCancel()
        }
    }
}
