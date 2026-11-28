import SwiftUI
import AppKit
import NoodleCore

/// A tool that is missing: its name and version, what will download, and progress with real megabytes.
struct SetupToolRow: View {
    let tool: SetupTool
    let pinVersion: String?
    let size: Int64?
    let download: SetupDownload?
    let checking: Bool
    let failed: Bool

    var body: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(tool.title).font(.headline)
                    if let pinVersion, !checking { Text(pinVersion).font(.body).foregroundStyle(.secondary) }
                }
                detailLine
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Space.panel).padding(.vertical, Space.m)
        .frame(maxWidth: .infinity, minHeight: SetupSheetContent.barHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var detailLine: some View {
        if checking {
            Text("Looking").font(.callout).foregroundStyle(.secondary)
        } else if let download {
            HStack(spacing: Space.m) {
                if let total = download.total, total > 0 {
                    ProgressView(value: Double(download.done), total: Double(total)).progressViewStyle(.linear).frame(maxWidth: 240)
                    Text("\(megabytes(download.done)) of \(megabytes(total))").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    ProgressView().progressViewStyle(.linear).frame(maxWidth: 240)
                }
            }
        } else {
            Text(tool.name != "docker" ? "Downloads on first use" : failed ? "Not installed" : "Downloads from download.docker.com")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var trailing: some View {
        if checking { ProgressView().controlSize(.small) }
        else if failed && tool.name == "docker" { SetupStatusMark(kind: .warning) }
        else if download == nil, let size { Text(megabytes(size)).font(.callout).monospacedDigit().foregroundStyle(.secondary) }
    }

    private func megabytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
