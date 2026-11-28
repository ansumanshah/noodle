import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NoodleEngine

/// Model-only HTTP facade for the unmodified upstream plugin. The Docker API stays Unix-only.
actor ModelRunnerServer {
    private struct Listener: Sendable { let channel: Channel; let connections: HTTPConnections }
    private let home: URL
    private let group: MultiThreadedEventLoopGroup
    private let router: Router
    private var access: ModelRunnerAccess?
    private var starting: Task<ModelRunnerConnection, Error>?
    private var local: Listener?
    private var bridges: [String: Listener] = [:]
    private var refreshing = false
    private var bridgeActive = false

    init(engine: Engine, group: MultiThreadedEventLoopGroup, runner: DockerModelRunner) {
        home = engine.paths.root
        self.group = group
        var table = RouteTable()
        Handlers(engine: engine).modelRunnerRoutes(&table, runner: runner)
        table.get("version") { _, writer in try await writer.json(["version": "noodle-" + APIInfo.serverVersion]) }
        router = Router(table: table)
    }

    func connection() async throws -> ModelRunnerConnection {
        if let access { return access.connection }
        if let starting { return try await starting.value }
        let task = Task { try await self.open() }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    private func open() async throws -> ModelRunnerConnection {
        let file = home.appendingPathComponent("models/docker-access.json")
        let saved: ModelRunnerAccess? = try await DockerModelRunner.disk {
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let saved = try JSONDecoder().decode(ModelRunnerAccess.self, from: Data(contentsOf: file))
            guard saved.key.utf8.count == 64, saved.key.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  (1024...65535).contains(saved.port) else { throw DockerModelRunnerError(500, "Invalid saved Model Runner connection") }
            return saved
        }
        for _ in 0..<16 {
            let candidate = saved ?? ModelRunnerAccess(key: (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined(),
                                                       port: Int.random(in: 49152...65535))
            try await DockerModelRunner.disk { NoodleOwnedPorts.shared.claim(candidate.port) }
            let listener: Listener
            do { listener = try await bind("127.0.0.1", access: candidate) } catch {
                try await DockerModelRunner.disk { NoodleOwnedPorts.shared.release(candidate.port) }
                if saved != nil { throw DockerModelRunnerError(503, "Saved Model Runner port is unavailable") }
                continue
            }
            do {
                try await DockerModelRunner.disk {
                    try PrivateFile.write(JSONEncoder().encode(candidate), to: file)
                }
            } catch {
                await close(listener)
                try await DockerModelRunner.disk { NoodleOwnedPorts.shared.release(candidate.port) }
                throw error
            }
            access = candidate
            local = listener
            await refreshBridges(active: true)
            return candidate.connection
        }
        throw DockerModelRunnerError(503, "No private Model Runner port is available")
    }

    func refreshBridges(active: Bool) async {
        bridgeActive = active
        guard !refreshing else { return }
        guard let access else { return }
        refreshing = true
        defer { refreshing = false }
        var intended: Bool
        repeat {
            intended = bridgeActive
            let addresses = intended ? await Engine.modelBridgeAddresses() : []
            for address in Array(bridges.keys) where !addresses.contains(address) {
                if let listener = bridges.removeValue(forKey: address) { await close(listener) }
            }
            for address in addresses where bridges[address] == nil {
                // A failed bridge bind never broadens the listener to a wildcard interface.
                if let listener = try? await bind(address, access: access) {
                    if bridgeActive { bridges[address] = listener }
                    else { await close(listener) }
                }
            }
        } while intended != bridgeActive
    }

    func stop() async {
        bridgeActive = false
        starting?.cancel()
        if let starting { _ = try? await starting.value }
        for listener in bridges.values { await close(listener) }
        bridges.removeAll()
        if let local { await close(local) }
        local = nil
        if let access { try? await DockerModelRunner.disk { NoodleOwnedPorts.shared.release(access.port) } }
        access = nil
    }

    private func bind(_ address: String, access: ModelRunnerAccess) async throws -> Listener {
        let connections = HTTPConnections()
        let router = self.router
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                guard connections.add(channel) else { return channel.close() }
                return channel.eventLoop.makeCompletedFuture {
                    let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes))
                    let encoder = HTTPResponseEncoder()
                    let parts = PipelineParts(decoder: decoder, encoder: encoder)
                    let handler = HTTPHandler(router: router, parts: parts, connections: connections)
                    parts.handler = handler
                    try channel.pipeline.syncOperations.addHandlers([decoder, encoder, ModelRunnerGuard(access: access), handler])
                }
            }.bind(host: address, port: access.port).get()
        return Listener(channel: channel, connections: connections)
    }

    private func close(_ listener: Listener) async {
        let clients = listener.connections.beginShutdown()
        try? await listener.channel.close().get()
        for client in clients { try? await client.close().get() }
        listener.connections.cancelTasks()
        for task in listener.connections.activeTasks() { await task.value }
    }
}

private final class ModelRunnerGuard: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPServerRequestPart
    private let access: ModelRunnerAccess
    private var rejected = false
    init(access: ModelRunnerAccess) { self.access = access }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !rejected else { return }
        var part = unwrapInboundIn(data)
        if case .head(var head) = part {
            let peer = context.channel.remoteAddress?.ipAddress
            do {
                head.uri = try access.target(head.uri, method: head.method, loopback: peer == "127.0.0.1" || peer == "::1")
                part = .head(head)
            } catch {
                rejected = true
                let error = error as? DockerModelRunnerError
                let body = context.channel.allocator.buffer(string: (error?.description ?? "Invalid model request") + "\n")
                let headers: HTTPHeaders = ["Content-Type": "text/plain", "Content-Length": String(body.readableBytes), "Connection": "close"]
                context.write(wrapOutbound(HTTPServerResponsePart.head(.init(version: .http1_1, status: .init(statusCode: error?.status ?? 400), headers: headers))), promise: nil)
                context.write(wrapOutbound(HTTPServerResponsePart.body(.byteBuffer(body))), promise: nil)
                let channel = context.channel
                context.writeAndFlush(wrapOutbound(HTTPServerResponsePart.end(nil))).whenComplete { _ in channel.close(promise: nil) }
                return
            }
        }
        context.fireChannelRead(wrapInboundOut(part))
    }

    private func wrapOutbound(_ value: HTTPServerResponsePart) -> NIOAny { NIOAny(value) }
}
