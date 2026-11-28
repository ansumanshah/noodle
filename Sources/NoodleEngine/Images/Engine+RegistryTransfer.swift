import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    // MARK: pull / push

    /// Decode the `X-Registry-Auth` header (base64url JSON).
    public nonisolated static func decodeRegistryAuth(_ header: String?) -> RegistryCredential? {
        guard var h = header, !h.isEmpty else { return nil }
        h = h.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while h.count % 4 != 0 { h += "=" }
        guard let d = Data(base64Encoded: h), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let user = o["username"] as? String, pass = o["password"] as? String
        let token = (o["identitytoken"] as? String) ?? (o["registrytoken"] as? String)
        if user == nil && pass == nil && token == nil { return nil }
        return RegistryCredential(username: user, password: pass, identityToken: token)
    }

    /// Pull, unpack into the guest as layers arrive. Events carry Docker's progress fields.
    public func pullImage(_ fromImage: String, tag: String? = nil, platform: String? = nil, registryAuth: String? = nil) -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var ref = fromImage
                    if let tag, !tag.isEmpty { ref = tag.hasPrefix("sha256:") ? "\(fromImage)@\(tag)" : "\(fromImage):\(tag)" }
                    let plat = platform.flatMap { Platform.parse($0) }
                    try await self.runPull(ref, platform: plat, credential: Self.decodeRegistryAuth(registryAuth)) { cont.yield($0) }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error is ImageError ? EngineError.internalError("\(error)") : error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    func runPull(_ ref: String, platform: Platform?, credential: RegistryCredential?, progress: @escaping ProgressHandler) async throws {
        defer { malloc_zone_pressure_relief(nil, 0) }   // hand freed download/unpack buffers back to the OS
        try await withActivity {
            let boot = Task { try await self.ensureGuest() }
            defer { boot.cancel() }
            do {
                _ = try await imageStore.pull(ref, platform: platform, credential: credential, progress: progress) { [self] layer in
                    try await boot.value
                    try await ensureLayer(layer)
                }
            } catch let e as ImageError {
                if case .notFound = e { throw EngineError.notFound("pull access denied for \(ref), repository does not exist or may require 'docker login'") }
                throw EngineError.internalError(e.description)
            }
            emit("image", "pull", id: ref, attributes: ["name": ref])
        }
    }

    public func pushImage(_ name: String, tag: String? = nil, registryAuth: String? = nil) -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var ref = name
                    if let tag, !tag.isEmpty { ref += tag.hasPrefix("sha256:") ? "@\(tag)" : ":\(tag)" }
                    try await self.withActivity {
                        _ = try await self.imageStore.push(ref, credential: Self.decodeRegistryAuth(registryAuth)) { cont.yield($0) }
                    }
                    await self.emit("image", "push", id: ref, attributes: ["name": ref])
                    cont.finish()
                } catch let e as ImageError {
                    cont.finish(throwing: e.isNotFound ? EngineError.notFound("An image does not exist locally with the tag: \(name)") : EngineError.internalError(e.description))
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
    /// `POST /auth`: check credentials against the registry. Nothing is stored here; the Docker CLI keeps its own credentials.
    public func registryLogin(serverAddress: String, username: String?, password: String?, identityToken: String?) async throws {
        let cred = RegistryCredential(username: username, password: password, identityToken: identityToken)
        do { try await imageStore.registry.login(serverAddress: serverAddress, credential: cred) }
        catch let e as ImageError {
            if case .unauthorized = e { throw EngineError.unauthorized(e.description) }
            throw EngineError.internalError(e.description)
        }
    }
}
