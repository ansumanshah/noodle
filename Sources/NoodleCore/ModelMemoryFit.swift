import Foundation

/// Whether a model suits this Mac, judged from installed memory only so the answer never depends on what is open.
public enum ModelMemoryFit: Sendable, Equatable {
    case good, tight, tooBig

    private static let gib: UInt64 = 1 << 30

    /// reserve = clamp(total / 8, 2, 8 GiB); need = bytes * 1.25 + 512 MB.
    /// `good` leaves half of what is left after the reserve free; `tight` still fits with 2 GiB to spare.
    public init(modelBytes: UInt64, totalMemory: UInt64) {
        let reserve = min(max(totalMemory / 8, 2 * Self.gib), 8 * Self.gib)
        let need = modelBytes &* 5 / 4 + 512 * (1 << 20)
        guard totalMemory >= reserve else { self = .tooBig; return }
        let usable = totalMemory - reserve
        if need <= usable / 2 {
            self = .good
        } else if usable >= 2 * Self.gib, need <= usable - 2 * Self.gib {
            self = .tight
        } else {
            self = .tooBig
        }
    }

    public init(modelBytes: UInt64) {
        self.init(modelBytes: modelBytes, totalMemory: ProcessInfo.processInfo.physicalMemory)
    }
}
