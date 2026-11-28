import NoodleCore
import SwiftUI

/// Green for a passed job, red for a failed one, a dotted ring while one runs, gray when none has run yet.
struct JobGlyph: View {
    let job: RunnerLastJob?
    let running: Bool
    private var look: (String, Color) {
        if running { return ("circle.dotted", .secondary) }
        guard let job else { return ("circle", .secondary) }
        return switch job.conclusion {
        case "success": ("checkmark.circle.fill", Status.running)
        case "failure", "cancelled", "timed_out": ("xmark.circle.fill", Status.error)
        default: ("minus.circle.fill", .secondary)
        }
    }

    var body: some View {
        let (symbol, tint) = look
        Image(systemName: symbol).foregroundStyle(tint).imageScale(.large)
            .symbolEffect(.rotate, isActive: running).accessibilityLabel(running ? "Running" : job?.conclusion ?? "No jobs yet")
    }
}
