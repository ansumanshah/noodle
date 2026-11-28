import Foundation

/// The power assertion calls, so the counting can be tested without touching IOKit.
public protocol PowerAssertions: Sendable {
    func create() -> UInt32?
    func release(_ id: UInt32)
}

/// Holds one assertion while at least one runner job is active and nothing while idle.
/// The real assertion also dies with the process, so a crashed helper never keeps the Mac awake.
public final class AwakeGuard: @unchecked Sendable {
    public static let reason = "Noodle: GitHub Actions job running"
    private let api: PowerAssertions
    private var held: UInt32?
    private let lock = NSLock()
    public init(api: PowerAssertions) { self.api = api }
    public var holding: Bool { lock.withLock { held != nil } }

    public func update(activeJobs: Int) {
        lock.withLock {
            if activeJobs > 0, held == nil { held = api.create() }
            else if activeJobs == 0, let id = held { api.release(id); held = nil }
        }
    }

    deinit { if let id = held { api.release(id) } }
}
