import AVFoundation
import AppKit
import ImageIO
import NoodleCore
import UniformTypeIdentifiers

/// Audio as a 16 kHz mono 16-bit WAV, the form `input_audio` and `/v1/audio/transcriptions` both read.
struct ModelAudioClip: Sendable, Equatable {
    var wav: Data
    /// Source file name, used in the "Transcribed from" note.
    var name: String = "audio"
    var duration: Double { ModelChatMedia.wavDuration(wav) }
}

extension ModelAudioClip {
    var message: LocalModelChat.Message.Audio { .init(base64: wav.base64EncodedString(), format: "wav") }
}
