import AVFoundation
import AppKit
import ImageIO
import NoodleCore
import UniformTypeIdentifiers

/// Video and audio attachments for Models chat. Limits, in one place:
/// video is sampled at about 1 frame per second, at most `maximumFrames` frames, long side `frameLongSide` px;
/// audio is converted to 16 kHz mono and refused above `maximumAudioSeconds` (5 minutes, about 9.6 MB of WAV).
enum ModelChatMedia {
    static let maximumFrames = 32
    static let frameLongSide = 512
    static let frameQuality = 0.7
    static let maximumAudioSeconds = 300.0
    static let audioRate = 16_000.0

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: Capability

    /// `input_modalities` (`["text","image","video","audio"]`) names what a model reads; `vision` in `capabilities` also means images.
    /// A lone row stands for the running model.
    static func support(modelsJSON: Data, model: String) -> ModelInputSupport {
        struct List: Decodable {
            struct Row: Decodable { let id: String?; let capabilities: [String]?; let input_modalities: [String]? }
            let data: [Row]
        }
        guard let rows = try? JSONDecoder().decode(List.self, from: modelsJSON).data,
              let row = rows.first(where: { $0.id == model }) ?? (rows.count == 1 ? rows[0] : nil) else { return .init() }
        let input = Set(row.input_modalities ?? [])
        return .init(images: input.contains("image") || row.capabilities?.contains("vision") == true,
                     video: input.contains("video"), audio: input.contains("audio"))
    }

    // MARK: Video

    /// Frame times in seconds: about one per second, at most `maximumFrames`, centred in equal slices of the clip.
    static func sampleTimes(duration: Double) -> [Double] {
        guard duration > 0 else { return [0] }
        let count = min(maximumFrames, max(1, Int(duration.rounded(.up))))
        return (0..<count).map { (Double($0) + 0.5) * duration / Double(count) }
    }

    static func videoClip(from url: URL) async throws -> ModelVideoClip {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw Failure("This file has no video.") }
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: frameLongSide, height: frameLongSide)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let times = sampleTimes(duration: duration.isFinite ? duration : 0)
        var frames: [Data] = []
        for await result in generator.images(for: times.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
            if case .success(_, let image, _) = result, let jpeg = jpeg(image) { frames.append(jpeg) }
        }
        guard !frames.isEmpty else { throw Failure("Couldn’t read frames from this video.") }
        return ModelVideoClip(duration: duration.isFinite ? duration : Double(frames.count), frames: frames)
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: frameQuality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    // MARK: Audio

    static func audioClip(from url: URL) async throws -> ModelAudioClip {
        let name = url.lastPathComponent
        return try await Task.detached { ModelAudioClip(wav: try wav(from: url), name: name) }.value
    }

    /// Decodes any file AVAudioFile reads and writes 16 kHz mono 16-bit PCM in a WAV container.
    static func wav(from url: URL) throws -> Data {
        guard let file = try? AVAudioFile(forReading: url) else { throw Failure("Couldn’t read this audio file.") }
        let source = file.processingFormat
        guard source.sampleRate > 0, Double(file.length) / source.sampleRate <= maximumAudioSeconds else {
            throw Failure("Audio is limited to \(Int(maximumAudioSeconds / 60)) minutes.")
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: audioRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384) else { throw Failure("Couldn’t convert this audio file.") }
        var pcm = Data()
        var finished = false
        while !finished {
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, inputStatus in
                input.frameLength = 0
                if (try? file.read(into: input)) != nil, input.frameLength > 0 {
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = .endOfStream
                return nil
            }
            if status == .error { throw Failure("Couldn’t convert this audio file.") }
            if let samples = output.int16ChannelData?[0] {
                pcm.append(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
            }
            finished = status == .endOfStream
        }
        guard !pcm.isEmpty else { throw Failure("This audio file is empty.") }
        return wavHeader(byteCount: pcm.count) + pcm
    }

    static func wavHeader(byteCount: Int) -> Data {
        var header = Data("RIFF".utf8)
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        put(UInt32(36 + byteCount)); header.append(Data("WAVEfmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(audioRate)); put(UInt32(audioRate) * 2); put(UInt16(2)); put(UInt16(16))
        header.append(Data("data".utf8)); put(UInt32(byteCount))
        return header
    }

    /// Our own files only: a 44-byte header and 16 kHz mono 16-bit samples.
    static func wavDuration(_ wav: Data) -> Double { Double(max(0, wav.count - 44)) / (audioRate * 2) }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Transcription fallback

    /// `POST /v1/audio/transcriptions` on the running server, which loads the named speech model on demand.
    static func transcribe(_ clip: ModelAudioClip, model: String, endpoint: LocalModelEndpoint) async throws -> String {
        let boundary = "noodle-" + UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "json")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(clip.wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("audio/transcriptions"), timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        struct Reply: Decodable { let text: String }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = try? JSONDecoder().decode(Reply.self, from: data).text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelPromptError("Couldn’t transcribe the audio. Check that the speech model is installed.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Files and pasteboard

    /// Movie and audio files on a pasteboard (paste and drag).
    static func mediaFiles(in pasteboard: NSPasteboard) -> [URL] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.filter { kind(of: $0) != nil }
    }

    enum Kind { case video, audio }

    static func kind(of url: URL) -> Kind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .movie) { return .video }
        return type.conforms(to: .audio) ? .audio : nil
    }

    // MARK: Previews

    /// The first frame with a duration badge in the corner, used in the composer and the transcript.
    static func badged(_ frame: NSImage, duration: Double) -> NSImage {
        let label = NSAttributedString(string: clock(duration), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(10, frame.size.height / 9), weight: .medium), .foregroundColor: NSColor.white])
        let pill = NSSize(width: label.size().width + 10, height: label.size().height + 4)
        return NSImage(size: frame.size, flipped: false) { rect in
            frame.draw(in: rect)
            let box = NSRect(x: rect.maxX - pill.width - 6, y: 6, width: pill.width, height: pill.height)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: box, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            label.draw(at: NSPoint(x: box.minX + 5, y: box.minY + 2))
            return true
        }
    }

    /// A compact audio chip for the transcript: waveform glyph and duration.
    static func audioChip(duration: Double, height: CGFloat = 40) -> NSImage {
        let label = NSAttributedString(string: clock(duration), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor])
        let glyph = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        let size = NSSize(width: label.size().width + 52, height: height)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.secondaryLabelColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            glyph?.tinted(.secondaryLabelColor).draw(at: NSPoint(x: 12, y: (height - 18) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            label.draw(at: NSPoint(x: 36, y: (height - label.size().height) / 2))
            return true
        }
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
