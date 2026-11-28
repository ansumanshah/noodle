import SwiftUI

/// One source for the engine line. The sidebar card and the toolbar status dot both read it, so they cannot disagree.
extension ConnectionModel {
    var engineStatusText: String {
        if let transition { return transition == .starting ? String(localized: "Starting engine…") : String(localized: "Stopping engine…") }
        if reconnecting || retryingConnection { return String(localized: "Reconnecting…") }
        if isUp, let label = vmReadiness?.label { return label }
        switch phase {
        case .up: return String(localized: "Engine running")
        case .connecting: return String(localized: "Connecting…")
        case .down: return String(localized: "Engine stopped")
        }
    }

    /// The VM pill on the sidebar card. When the engine answers but reports no VM detail (older daemon, demo), the VM is
    /// running: it never reads "Unavailable" next to a running engine.
    var vmStateText: String {
        if let transition { return transition == .starting ? String(localized: "Starting") : String(localized: "Stopping") }
        switch phase {
        case .connecting: return String(localized: "Connecting")
        case .down: return reconnecting || retryingConnection ? String(localized: "Reconnecting") : String(localized: "Offline")
        case .up:
            switch vmReadiness?.state {
            case "running", nil: return String(localized: "Running")
            case "starting": return vmReadiness?.vmRunning == true ? String(localized: "Connecting") : String(localized: "Starting")
            case "stopping": return String(localized: "Stopping")
            case "stopped": return (vmReadiness?.bootCount ?? 0) > 0 ? String(localized: "Asleep") : String(localized: "Off")
            default: return String(localized: "Unavailable")
            }
        }
    }

    /// The VM pill reads "Running". Mirrors `vmStateText`, so nothing compares display text.
    var vmRunningNow: Bool {
        guard transition == nil, phase == .up else { return false }
        return vmReadiness?.state == "running" || vmReadiness?.state == nil
    }

    /// True while the engine is changing state, so a spinner replaces the dot.
    var engineBusy: Bool {
        transition != nil || phase == .connecting || reconnecting || retryingConnection || (isUp && vmReadiness?.label != nil)
    }
}
