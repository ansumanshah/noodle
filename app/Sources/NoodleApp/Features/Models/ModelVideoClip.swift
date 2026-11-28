import AVFoundation
import AppKit
import ImageIO
import NoodleCore
import UniformTypeIdentifiers

/// A video reduced to sampled JPEG frames (what mlx-serve's `video_url` part takes; it has no video codec).
struct ModelVideoClip: Codable, Sendable, Equatable {
    var duration: Double
    var frames: [Data]
    var fps: Double { duration > 0 ? Double(frames.count) / duration : 1 }
}

extension ModelVideoClip {
    var message: LocalModelChat.Message.Video {
        .init(frames: frames.map(ModelChatAttachments.dataURL), fps: fps)
    }
}
