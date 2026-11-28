import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NoodleEngine

/// The pipeline pieces a hijack needs to take apart.
final class PipelineParts: @unchecked Sendable {
    let decoder: ByteToMessageHandler<HTTPRequestDecoder>
    let encoder: HTTPResponseEncoder
    /// Weak: the pipeline owns the handler, and the handler owns these parts. Hijack removes it from the pipeline.
    weak var handler: HTTPHandler?
    init(decoder: ByteToMessageHandler<HTTPRequestDecoder>, encoder: HTTPResponseEncoder) {
        self.decoder = decoder; self.encoder = encoder
    }
}
