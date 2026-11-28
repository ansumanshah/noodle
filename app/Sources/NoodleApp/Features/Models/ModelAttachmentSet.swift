import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Everything attached to one message.
struct ModelAttachmentSet: Sendable {
    var images: [Data] = []
    var video: ModelVideoClip?
    var audio: ModelAudioClip?
    var isEmpty: Bool { images.isEmpty && video == nil && audio == nil }
}
