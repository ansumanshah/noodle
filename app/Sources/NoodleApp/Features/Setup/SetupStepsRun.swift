import SwiftUI
import AppKit
import NoodleCore

/// First container: the steps while they run, then the real command, its output and the measured time.
struct SetupFirstPage: View {
    let flow: SetupFlow
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SetupPageHeader(title: flow.header.title, detail: flow.stage == .failed ? flow.header.detail : "")
                if flow.stage == .done { result } else {
                    SetupList {
                        ForEach(Array(flow.progressRows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { SetupRule() }
                            SetupStatusRow(row: row)
                        }
                    }
                    if flow.stage == .install, let start = flow.applyStartedAt {
                        SetupApplyProgress(startedAt: start, waiting: flow.applyWait)
                    }
                    if flow.problem == .pathNotApplied || flow.problem == .unsupportedShell { SetupCode(text: SetupPlan.pathLine) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var result: some View {
        VStack(alignment: .leading, spacing: 20) {
            CommandBlock(command: flow.firstCommand, output: flow.transcript)
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(SetupProgress.duration(milliseconds: flow.milliseconds ?? 0)).font(.title3.weight(.semibold)).monospacedDigit()
                Text("from command to exit").font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Button(copied ? "Copied" : "Copy Command") {
                copyToPasteboard(flow.firstCommand)
                copied = true
            }
            .motion(Motion.snappy, value: copied)
            SetupComposeNextStep(command: flow.composeCommand, check: flow.composeCheck)
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(notes, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let line = flow.pathReminder {
                    Text("Terminal can’t find docker yet. Add this to your shell profile:").font(.callout).foregroundStyle(.secondary)
                    SetupCode(text: line)
                }
                HStack(spacing: Space.xs) {
                    Text("To undo").font(.callout).foregroundStyle(.secondary)
                    SetupCode(text: "noodle uninstall")
                }
            }
        }
    }

    private var notes: [String] {
        var result: [String] = []
        if let note = flow.importNote { result.append(note) }
        if let note = flow.overrideNote { result.append(note) }
        if !flow.missingTools.isEmpty {
            result.append("Not installed: " + flow.missingTools.map { $0.replacingOccurrences(of: "docker-", with: "").capitalized }.joined(separator: ", "))
        }
        return result
    }
}
