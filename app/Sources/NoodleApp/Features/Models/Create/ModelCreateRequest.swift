import Foundation
import NoodleCore

/// What Create makes. Each kind maps to one model kind and one mlx-serve endpoint.
enum ModelCreateKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case image, speech, video
    var id: Self { self }

    var title: String {
        switch self {
        case .image: String(localized: "Image")
        case .speech: String(localized: "Speech")
        case .video: String(localized: "Video")
        }
    }
    var modelKind: LocalModelKind {
        switch self { case .image: .imageGeneration; case .speech: .textToSpeech; case .video: .videoGeneration }
    }
    var path: String {
        switch self { case .image: "images/generations"; case .speech: "audio/speech"; case .video: "video/generations" }
    }
    init?(_ kind: LocalModelKind) {
        guard let match = Self.allCases.first(where: { $0.modelKind == kind }) else { return nil }
        self = match
    }
}

/// The controls each kind shows: size, steps and seed for images, voice for speech, length for video.
struct ModelCreateOptions: Equatable, Sendable {
    var size = "1024x1024"
    var steps = 4
    /// Nil picks a new random seed each time.
    var seed: Int?
    var voice = "af_heart"
    /// LTX makes 8k+1 frames at 24 fps: 49 is about 2 seconds, 97 about 4.
    var frames = 49

    static let sizes = ["512x512", "768x768", "1024x1024", "1024x768", "768x1024"]
    static let voices = ["af_heart", "af_bella", "af_nicole", "af_sky", "am_adam", "am_michael",
                         "bf_emma", "bf_isabella", "bm_george", "bm_lewis"]
}

enum ModelCreateRequest {
    /// The JSON body mlx-serve's media endpoints take. `editImage` turns an image request into an edit of that picture,
    /// which keeps the source's own size.
    static func body(kind: ModelCreateKind, model: String, prompt: String, options: ModelCreateOptions,
                     editImage: Data? = nil) -> [String: Any] {
        var body: [String: Any] = ["model": MLXServeLaunch.modelID(model), "stream": true]
        switch kind {
        case .image:
            body["prompt"] = prompt
            body["steps"] = options.steps
            if let seed = options.seed { body["seed"] = seed }
            if let editImage {
                body["image"] = editImage.base64EncodedString()
                body["mode"] = "edit"
            } else {
                body["size"] = options.size
            }
        case .speech:
            body["input"] = prompt
            body["voice"] = options.voice
            body["speed"] = 1.0
        case .video:
            body["prompt"] = prompt
            body["num_frames"] = options.frames
            body["width"] = 768
            body["height"] = 512
            body["steps"] = 8
            body["preview"] = true
            if let seed = options.seed { body["seed"] = seed }
        }
        return body
    }

    static func urlRequest(kind: ModelCreateKind, body: [String: Any], endpoint: LocalModelEndpoint) throws -> URLRequest {
        // Generation can take minutes; the stream's keepalives hold the connection open.
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent(kind.path), timeoutInterval: 900)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
}
