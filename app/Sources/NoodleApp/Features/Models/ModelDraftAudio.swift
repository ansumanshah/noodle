import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Audio waiting in the composer.
struct ModelDraftAudio: Identifiable {
    let id = UUID()
    let clip: ModelAudioClip
}
