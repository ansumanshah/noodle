import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// What the running model reads, from `GET /v1/models`.
struct ModelInputSupport: Equatable, Sendable {
    var images = false
    var video = false
    var audio = false
}
