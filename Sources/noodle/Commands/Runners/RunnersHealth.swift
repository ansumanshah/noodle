import Darwin
import Foundation
import NoodleCore

/// Reads the real Mac: one resource read and one sysctl, no timer.
struct SystemRunnerHealth: RunnerHealthProbe {
    func freeBytes() -> Int64? { RunnerHealth.freeBytes(near: runnerStore.directory.path) }
    func pressure() -> RunnerPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return RunnerPressure(rawValue: Int(level)) ?? (level > 2 ? .critical : .normal)
    }
}

/// Remembers the last decision, which the recovery margin depends on.
struct RunnerHealthGate {
    private(set) var hold: RunnerHold?
    mutating func check(_ probe: RunnerHealthProbe) -> RunnerHold? {
        hold = RunnerHealth.decide(freeBytes: probe.freeBytes(), pressure: probe.pressure(), previous: hold)
        return hold
    }
}
