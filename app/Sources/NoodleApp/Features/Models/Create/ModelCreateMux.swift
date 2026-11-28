@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Writes raw rgb8 frames and s16le audio into an H.264 + AAC .mp4. It runs off the main actor: a 4 second clip is
/// close to 100 MB of pixels.
enum ModelCreateMux {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { String(localized: "Couldn’t save the video: \(reason)") }
    }

    @concurrent
    static func write(_ frames: ModelCreateFrames, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: frames.width, AVVideoHeightKey: frames.height,
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: frames.width, kCVPixelBufferHeightKey as String: frames.height,
        ])
        writer.add(video)
        var audio: AVAssetWriterInput?
        if let pcm = frames.pcm, !pcm.isEmpty {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: frames.sampleRate,
                AVNumberOfChannelsKey: frames.channels,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audio = input
        }
        guard writer.startWriting() else { throw Failure(reason: writer.error?.localizedDescription ?? "writer") }
        writer.startSession(atSourceTime: .zero)

        let frameBytes = frames.width * frames.height * 3
        for index in 0..<frames.count {
            try await ready(video)
            guard let pool = adaptor.pixelBufferPool else { throw Failure(reason: "no pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw Failure(reason: "no pixel buffer") }
            fill(buffer, rgb: frames.rgb, offset: index * frameBytes, width: frames.width, height: frames.height)
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(max(1, frames.fps)))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw Failure(reason: writer.error?.localizedDescription ?? "frame \(index)")
            }
        }
        video.markAsFinished()
        if let audio, let pcm = frames.pcm {
            try await ready(audio)
            guard audio.append(try sampleBuffer(pcm, rate: frames.sampleRate, channels: frames.channels)) else {
                throw Failure(reason: writer.error?.localizedDescription ?? "audio")
            }
            audio.markAsFinished()
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure(reason: writer.error?.localizedDescription ?? "finish") }
    }

    private static func ready(_ input: AVAssetWriterInput) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func fill(_ buffer: CVPixelBuffer, rgb: Data, offset: Int, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        rgb.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            let pixels = source.bindMemory(to: UInt8.self)
            for row in 0..<height {
                let line = base + row * stride
                for column in 0..<width {
                    let from = offset + (row * width + column) * 3
                    let to = column * 4
                    line[to] = pixels[from + 2]; line[to + 1] = pixels[from + 1]; line[to + 2] = pixels[from]; line[to + 3] = 255
                }
            }
        }
    }

    /// One sample buffer for the whole track; the writer splits it into AAC packets.
    private static func sampleBuffer(_ pcm: Data, rate: Int, channels: Int) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(
            mSampleRate: Float64(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        let usable = pcm.count - pcm.count % (2 * channels)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: usable, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: usable, flags: 0, blockBufferOut: &block)
        guard let block, let description, usable > 0 else { throw Failure(reason: "audio format") }
        let copied = pcm.withUnsafeBytes { raw in
            raw.baseAddress.map { CMBlockBufferReplaceDataBytes(with: $0, blockBuffer: block, offsetIntoDestination: 0, dataLength: usable) }
        }
        guard copied == noErr else { throw Failure(reason: "audio copy") }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: description, sampleCount: usable / (2 * channels),
            presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample else { throw Failure(reason: "audio buffer") }
        return sample
    }
}
