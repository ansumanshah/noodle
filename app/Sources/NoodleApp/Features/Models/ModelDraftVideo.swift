import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A video waiting in the composer, with its first frame for display.
struct ModelDraftVideo: Identifiable {
    let id = UUID()
    let clip: ModelVideoClip
    let thumbnail: NSImage

    init?(_ clip: ModelVideoClip) {
        guard let first = clip.frames.first, let image = NSImage(data: first) else { return nil }
        self.clip = clip
        thumbnail = image
    }
}
