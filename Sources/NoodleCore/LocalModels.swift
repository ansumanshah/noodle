import Foundation

public enum LocalModelBackend: String, Codable, Sendable {
    case llamaCPP = "llama.cpp"
    case mlx

    public var displayName: String {
        switch self {
        case .llamaCPP: "llama.cpp · Metal"
        case .mlx: "MLX · Metal"
        }
    }
}

/// What a model is for. Only `chat` models belong in the chat picker; the others are served as API only.
public enum LocalModelKind: String, Codable, Sendable, CaseIterable {
    case chat, embeddings, speechToText, textToSpeech, imageGeneration, videoGeneration

    public var isSpeech: Bool { self == .speechToText || self == .textToSpeech }
    /// Models the Create area makes things with: images, voice and video.
    public var isCreative: Bool { self == .imageGeneration || self == .videoGeneration || self == .textToSpeech }
}

public struct LocalModel: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let bytes: UInt64
    public let installed: Bool
    public let downloadable: Bool
    public let backend: LocalModelBackend
    public let kind: LocalModelKind

    public init(id: String, name: String, bytes: UInt64, installed: Bool, downloadable: Bool,
                backend: LocalModelBackend = .llamaCPP, kind: LocalModelKind = .chat) {
        self.id = id
        self.name = name
        self.bytes = bytes
        self.installed = installed
        self.downloadable = downloadable
        self.backend = backend
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case id, name, bytes, installed, downloadable, backend, kind }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        bytes = try values.decode(UInt64.self, forKey: .bytes)
        installed = try values.decode(Bool.self, forKey: .installed)
        downloadable = try values.decode(Bool.self, forKey: .downloadable)
        backend = try values.decodeIfPresent(LocalModelBackend.self, forKey: .backend) ?? .llamaCPP
        kind = try values.decodeIfPresent(LocalModelKind.self, forKey: .kind) ?? .chat
    }
}

public struct LocalModelPullProgress: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case downloading, verifying, installed
    }

    public let phase: Phase
    public let receivedBytes: UInt64
    public let totalBytes: UInt64

    public init(phase: Phase, receivedBytes: UInt64, totalBytes: UInt64) {
        self.phase = phase
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }
}

public struct LocalModelStatus: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case stopped, starting, ready
    }

    public let phase: Phase
    public let model: String?
    public let baseURL: URL?
    public let workloadBaseURL: URL?
    /// A local name verified against the active model. The direct baseURL remains available.
    public let namedBaseURL: URL?
    public let backend: LocalModelBackend?
    /// Runtime restarts after crashes, and the last log lines of the latest one. Absent in older output.
    public let restarts: Int?
    public let lastCrash: String?

    public init(phase: Phase, model: String? = nil, baseURL: URL? = nil, workloadBaseURL: URL? = nil,
                backend: LocalModelBackend? = nil, namedBaseURL: URL? = nil,
                restarts: Int? = nil, lastCrash: String? = nil) {
        self.restarts = restarts
        self.lastCrash = lastCrash
        self.phase = phase
        self.model = model
        self.baseURL = baseURL
        self.workloadBaseURL = workloadBaseURL
        self.namedBaseURL = namedBaseURL
        self.backend = backend
    }
}

public struct LocalModelEndpoint: Codable, Sendable {
    public let model: String
    public let baseURL: URL
    public let workloadBaseURL: URL?
    /// A local name verified against the active model. The direct baseURL remains available.
    public let namedBaseURL: URL?
    public let apiKey: String
    public let backend: LocalModelBackend?

    public init(model: String, baseURL: URL, workloadBaseURL: URL? = nil, apiKey: String,
                backend: LocalModelBackend? = nil, namedBaseURL: URL? = nil) {
        self.model = model
        self.baseURL = baseURL
        self.workloadBaseURL = workloadBaseURL
        self.namedBaseURL = namedBaseURL
        self.apiKey = apiKey
        self.backend = backend
    }
}

public enum LocalModelChat {
    public struct Message: Encodable, Sendable {
        public enum Role: String, Encodable, Sendable {
            case system, user, assistant
        }

        public struct Video: Sendable {
            /// `data:image/jpeg;base64,...` frames in order.
            public let frames: [String]
            /// Sampling rate in frames per second; sent so the model can place frames in time.
            public let fps: Double?
            public init(frames: [String], fps: Double? = nil) { self.frames = frames; self.fps = fps }
        }

        public struct Audio: Sendable {
            public let base64: String
            /// mlx-serve accepts `wav`, `pcm16` (24 kHz) and `mlx_pcm_f32` (16 kHz).
            public let format: String
            public init(base64: String, format: String = "wav") { self.base64 = base64; self.format = format }
        }

        let role: Role
        let content: String
        /// `data:image/jpeg;base64,...` URLs. Sent as `image_url` parts after the text; mlx-serve does not fetch remote URLs.
        let imageURLs: [String]
        let videos: [Video]
        let audios: [Audio]

        public init(role: Role, content: String, imageURLs: [String] = [], videos: [Video] = [], audios: [Audio] = []) {
            self.role = role
            self.content = content
            self.imageURLs = imageURLs
            self.videos = videos
            self.audios = audios
        }

        /// The same message with a transcript in place of its audio, for models that cannot hear.
        public func replacingAudio(with transcript: String, source: String) -> Message {
            let note = "[Transcribed from \(source)]\n\(transcript)"
            return Message(role: role, content: content.isEmpty ? note : content + "\n\n" + note,
                           imageURLs: imageURLs, videos: videos, audios: [])
        }

        private enum CodingKeys: String, CodingKey { case role, content }
        private struct Part: Encodable {
            struct Image: Encodable { let url: String }
            struct VideoPart: Encodable { let frames: [String]; let fps: Double? }
            struct AudioPart: Encodable { let data: String; let format: String }
            let type: String
            var text: String?
            var image_url: Image?
            var video_url: VideoPart?
            var input_audio: AudioPart?
        }

        /// Plain string content without media (every existing caller); an OpenAI parts array with it.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            guard !(imageURLs.isEmpty && videos.isEmpty && audios.isEmpty) else { return try container.encode(content, forKey: .content) }
            // A media-only message carries no empty text part.
            var parts = content.isEmpty ? [] : [Part(type: "text", text: content)]
            parts += imageURLs.map { Part(type: "image_url", image_url: .init(url: $0)) }
            parts += videos.map { Part(type: "video_url", video_url: .init(frames: $0.frames, fps: $0.fps)) }
            parts += audios.map { Part(type: "input_audio", input_audio: .init(data: $0.base64, format: $0.format)) }
            try container.encode(parts, forKey: .content)
        }
    }

    /// `maxTokens` is omitted from the JSON when nil, so the model and server decide the reply length.
    public static func body(model: String, messages: [Message], maxTokens: Int? = nil) throws -> Data {
        struct Request: Encodable {
            let model: String
            let messages: [Message]
            let max_tokens: Int?
            let chat_template_kwargs = ["enable_thinking": false]
        }
        return try JSONEncoder().encode(Request(model: model, messages: messages, max_tokens: maxTokens))
    }

    public static func reply(from data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Reply: Decodable { let content: String? }
                let message: Reply
            }
            let choices: [Choice]
        }
        guard let reply = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content,
              !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CocoaError(.coderValueNotFound, userInfo: [NSLocalizedDescriptionKey: "The model returned an empty reply."])
        }
        return reply
    }
}
