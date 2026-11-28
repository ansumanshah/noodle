import Foundation

/// The system's own memory pressure level (`kern.memorystatus_vm_pressure_level`: 1, 2, 4).
public enum RunnerPressure: Int, Sendable { case normal = 1, warning = 2, critical = 4 }

/// What the helper reads before it starts a runner. A seam so tests can fake the Mac.
public protocol RunnerHealthProbe: Sendable {
    /// Free bytes on the volume holding the Noodle home, or nil when it cannot be read.
    func freeBytes() -> Int64?
    func pressure() -> RunnerPressure
}

public enum RunnerHold: Equatable, Sendable {
    case disk(freeBytes: Int64, needsBytes: Int64)
    case memory(RunnerPressure)

    /// The line shown by `noodle runners status` and `list`.
    public var text: String {
        switch self {
        case let .disk(free, needs): "Holding new jobs: \(free / RunnerHealth.gigabyte) GB free on the Noodle volume, needs \(needs / RunnerHealth.gigabyte) GB"
        case .memory: "Holding new jobs: this Mac is low on memory"
        }
    }
}

public enum RunnerHealth {
    /// Free bytes on the volume holding `path`, measured at the nearest folder that exists (the home may not exist yet).
    /// A fresh URL each call: a URL caches resource values, so a reused one would report the first reading forever.
    public static func freeBytes(near path: String) -> Int64? {
        var dir = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: dir.path), dir.path != "/" { dir.deleteLastPathComponent() }
        return (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    public static let gigabyte: Int64 = 1_000_000_000
    /// Hold below 10 GB: a job checks out a repo, pulls an image layer or two and writes build output, and a full disk
    /// fails the job (and everything else on the Mac) halfway through.
    public static let holdBytes = 10 * gigabyte
    /// Resume only at 15 GB, so a job finishing and freeing a little space does not flip the helper between hold and take.
    public static let resumeBytes = 15 * gigabyte

    /// Nil means take the job. Memory holds only at the critical level: warning is routine on a 16 GB Mac running a VM
    /// and a build, and holding there would starve the queue. The system's level switches back with its own margin,
    /// so critical resumes at warning or normal. Unreadable disk space or pressure never holds.
    public static func decide(freeBytes: Int64?, pressure: RunnerPressure, previous: RunnerHold?,
                              holdBelow: Int64 = holdBytes, resumeAt: Int64 = resumeBytes) -> RunnerHold? {
        var needs = holdBelow
        if case .disk? = previous { needs = resumeAt }
        // Disk first: a disk hold stays the published hold through critical memory, so its resume margin is not lost.
        if let free = freeBytes, free < needs { return .disk(freeBytes: free, needsBytes: needs) }
        return pressure == .critical ? .memory(pressure) : nil
    }
}
