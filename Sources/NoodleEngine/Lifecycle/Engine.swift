import Foundation
import OSLog
@_exported import NoodleCore
@_exported import NoodleImages
@_exported import NoodleVM

/// The container engine. One instance per daemon; every Docker API call maps to a method here.
/// Host-only calls (list, inspect, create, rm of stopped containers, images, networks, volumes) never boot the VM.
public actor Engine {
    public nonisolated let paths: NoodlePaths
    /// The main VM and its client: ordinary containers, images, builds.
    public nonisolated let vm: VMController
    public nonisolated let guest: GuestClient
    nonisolated let main: GuestRuntime
    nonisolated let workload: GuestRuntime
    public nonisolated let imageStore: ImageStore
    nonisolated let hostEvents: HostFileEvents
    let log = Logger(subsystem: "app.noodle", category: "engine")
    let hub = EventHub()
    nonisolated static let serverVersion = "26.11.8"
    nonisolated static let apiVersion = "1.51"
    nonisolated static let minAPIVersion = "1.24"

    var settings: VMSettings
    var proxy: ProxySettings
    /// The main VM's Mac loopback relay; nil when `host_loopback` is off.
    var hostLoopbackRelay: HostLoopbackRelay?
    var modelBridgeObserver: (@Sendable (Bool) async -> Void)?
    var containers: [String: ContainerRecord] = [:]
    /// Image removals in flight. A container created meanwhile could reference an image the store is deleting.
    var imageRemovals = 0
    var networks: [String: NetworkRecord] = [:]
    var ipams: [String: IPAM] = [:]
    var ipams6: [String: IPAM6] = [:]
    var volumes: [String: VolumeRecord] = [:]
    var execs: [String: ExecRecord] = [:]
    var pendingRemovals = PendingRemovals()
    var deletingVolumes: Set<String> = []

    var locks: [String: [CheckedContinuation<Void, Never>]] = [:]
    var held: Set<String> = []
    var starting: Set<String> = []
    /// Containers inside `restartContainer` (stop, then start). A container joining their network namespace waits for them.
    var restartingIDs: Set<String> = []
    /// Streams opened on a container that has not started yet, ended if its start fails.
    var attachesBeforeStart: [String: [GuestStream]] = [:]
    var pendingExits: [String: Int32] = [:]
    var exitWaiters: [String: [UUID: CheckedContinuation<WaitResult?, Never>]] = [:]
    var listeners: [String: [PortListener]] = [:]
    var nameRouter: NameRouter?
    var nameTable: [LocalNames.Target] = []
    var namesError: String?
    /// Persisted names for host processes (`noodle names add`): label -> loopback port.
    var hostRoutes: [String: Int] = [:]
    var restartTasks: [String: Task<Void, Never>] = [:]
    var nativeBuilder: Task<NativeBuilder, Error>?
    var nativeGeneration: UUID?
    var nativeImportOwner: NativeBuilder?
    var nativeConnections = Set<UUID>()
    /// Blob digests the running native builder may read back from the Mac, grown as it resolves bases.
    var nativeBaseBlobs = Set<String>()
    var releaseNativeBuilder: Task<Void, Never>?
    var healthTasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    var activeOps = 0
    var saveScheduled = false
    var started = false
    /// Set once `shutdown()` begins: a VM stop then is the daemon leaving, not a crash that restart policies should answer.
    var shuttingDown = false

    struct PendingRemovals: Codable {
        var containers: [String] = []
        var volumes: [String] = []
        var layers: [String] = []
        /// Same lists for the workload VM, present only while it has something pending.
        var workload: Lists?

        struct Lists: Codable {
            var containers: [String] = []
            var volumes: [String] = []
            var layers: [String] = []
            var isEmpty: Bool { containers.isEmpty && volumes.isEmpty && layers.isEmpty }
        }
    }

    public init(paths: NoodlePaths = .resolve(), settings: VMSettings? = nil) {
        self.paths = paths
        let s = settings ?? VMSettings.load(paths: paths)
        self.settings = s
        self.proxy = ProxySettings.load(from: paths.proxyFile)
        let mainRuntime = GuestRuntime(role: .main, paths: paths, settings: s)
        self.main = mainRuntime
        self.workload = GuestRuntime(role: .workload, paths: paths, settings: s)
        self.vm = mainRuntime.vm
        let client = mainRuntime.guest
        self.guest = client
        self.hostEvents = HostFileEvents { paths in
            Task {
                // Paths still stale wait out the guest's cache-drop interval; without this a rapid second save is lost.
                for _ in 0..<3 {
                    let reply = try? await client.call(GuestOp.fsPoke, ["paths": .strings(paths)], boot: false)
                    guard (reply?["stale"]?.int ?? 0) > 0 else { return }
                    try? await Task.sleep(for: .milliseconds(110))
                }
            }
        }
        self.imageStore = ImageStore(paths: paths)
    }

}
