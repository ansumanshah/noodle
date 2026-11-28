import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NoodleEngine

/// The Docker Engine API on a unix socket. One or two event-loop threads, no timers.
public final class DockerServer: @unchecked Sendable {
    public let socketPath: String
    /// Guest containers reach the API through this socket only, so the router can refuse Noodle's own routes there.
    public let guestSocketPath: String?
    private let engine: Engine
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?
    private var guestChannel: Channel?
    private var modelServer: ModelRunnerServer?
    private let connections = HTTPConnections()

    public init(engine: Engine, socketPath: String, guestSocketPath: String? = nil, threads: Int = 1) {
        self.engine = engine
        self.socketPath = socketPath
        self.guestSocketPath = guestSocketPath
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: max(1, min(threads, 2)))
    }

    public func start() async throws {
        let runner = DockerModelRunner(home: engine.paths.root)
        let models = ModelRunnerServer(engine: engine, group: group, runner: runner)
        modelServer = models
        await engine.setModelBridgeObserver { [weak models] active in await models?.refreshBridges(active: active) }
        var table = Handlers(engine: engine, modelConnection: { try await models.connection() }).routes(modelRunner: runner)
        table.get("noodle/model-runner/connection") { _, writer in try await writer.json(try await models.connection()) }
        let router = Router(table: table)
        channel = try await listen(socketPath, router: router, relayed: false)
        if let guestSocketPath { guestChannel = try await listen(guestSocketPath, router: router, relayed: true) }
    }

    private func listen(_ path: String, router: Router, relayed: Bool) async throws -> Channel {
        let connections = self.connections
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                guard connections.add(channel) else { return channel.close() }
                return channel.eventLoop.makeCompletedFuture {
                    let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                    let encoder = HTTPResponseEncoder()
                    let parts = PipelineParts(decoder: decoder, encoder: encoder)
                    let handler = HTTPHandler(router: router, parts: parts, connections: connections, relayed: relayed)
                    parts.handler = handler
                    try channel.pipeline.syncOperations.addHandlers([decoder, encoder, handler])
                }
            }
        let ch = try await bootstrap.bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true).get()
        chmod(path, 0o600)
        return ch
    }

    /// Close the listener and clients before the engine is shut down.
    public func stopAccepting() async {
        await engine.setModelBridgeObserver(nil)
        await modelServer?.stop()
        modelServer = nil
        let clients = connections.beginShutdown()
        for ch in [channel, guestChannel].compactMap({ $0 }) { try? await ch.close().get() }
        channel = nil; guestChannel = nil
        unlink(socketPath)
        if let guestSocketPath { unlink(guestSocketPath) }
        for client in clients { try? await client.close().get() }
        connections.cancelTasks()
    }

    /// Drain request callbacks while event loops are still available.
    public func stop() async {
        let tasks = connections.activeTasks()
        for task in tasks { await task.value }
        for loop in connections.eventLoops() { try? await loop.submit {}.get() }
        try? await group.shutdownGracefully()
    }
}

/// Tracks clients and their request tasks, including requests that hijack their HTTP pipeline.
final class HTTPConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var shuttingDown = false
    private var clients: [ObjectIdentifier: Channel] = [:]
    private var loops: [ObjectIdentifier: EventLoop] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func add(_ channel: Channel) -> Bool {
        lock.lock()
        guard !shuttingDown else { lock.unlock(); return false }
        clients[ObjectIdentifier(channel)] = channel
        loops[ObjectIdentifier(channel.eventLoop)] = channel.eventLoop
        lock.unlock()
        channel.closeFuture.whenComplete { [weak self] _ in self?.remove(channel) }
        return true
    }
    private func remove(_ channel: Channel) {
        lock.lock(); defer { lock.unlock() }
        clients.removeValue(forKey: ObjectIdentifier(channel))
    }
    func addTask(_ task: Task<Void, Never>, id: UUID) {
        lock.lock(); defer { lock.unlock() }
        tasks[id] = task
        if shuttingDown { task.cancel() }
    }
    func removeTask(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        tasks.removeValue(forKey: id)
    }
    func beginShutdown() -> [Channel] {
        lock.lock(); defer { lock.unlock() }
        shuttingDown = true
        return Array(clients.values)
    }
    func cancelTasks() {
        lock.lock(); let pending = Array(tasks.values); lock.unlock()
        for task in pending { task.cancel() }
    }
    func activeTasks() -> [Task<Void, Never>] {
        lock.lock(); defer { lock.unlock() }
        return Array(tasks.values)
    }
    func eventLoops() -> [EventLoop] {
        lock.lock(); defer { lock.unlock() }
        return Array(loops.values)
    }
}
