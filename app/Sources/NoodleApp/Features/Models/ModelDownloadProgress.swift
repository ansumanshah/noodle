import NoodleCore
import SwiftUI

struct ModelActiveDownload: View {
    let model: LocalModel?
    let id: String
    let progress: LocalModelPullProgress?
    let cancelling: Bool
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.down").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(WorkspaceStyle.models.ink)
                    .frame(width: Tile.size, height: Tile.size)
                    .background(WorkspaceStyle.models.soft, in: .rect(cornerRadius: Radius.panel, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model?.name ?? id).font(.headline).accessibilityAddTraits(.isHeader)
                    Text(model.map { ModelLibraryPolicy.size($0.bytes) } ?? "Model download").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                let title = cancelling ? "Cancelling…" : "Cancel Download"
                Button(title, systemImage: "xmark.circle.fill", action: cancel)
                    .labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill().font(.title3)
                    .foregroundStyle(.secondary)
                    .disabled(cancelling || progress?.phase == .installed)
                    .help(title).accessibilityLabel(title)
            }
            ModelDownloadProgressView(progress: progress)
            Divider()
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "checkmark.shield").accessibilityHidden(true)
                Text("Noodle checks the files before adding this model to your library.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .cardSurface()
    }
}

struct ModelDownloadProgressView: View {
    let progress: LocalModelPullProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress, let fraction = ModelLibraryPolicy.transferFraction(progress) {
                let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
                HStack(spacing: 10) {
                    Text(progress.phase == .installed ? "Download complete" : "Downloading model").font(.callout.weight(.medium))
                    Spacer(minLength: 0)
                    Text(percent).font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(.primary)
                }
                ModelProgressBar(fraction: fraction)
                    .accessibilityLabel("Model download").accessibilityValue(percent)
                Text("\(progress.receivedBytes.formatted(.byteCount(style: .file))) of \(progress.totalBytes.formatted(.byteCount(style: .file)))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(progress?.phase == .verifying ? "Verifying download" : "Preparing download")
                        .font(.callout.weight(.medium))
                }
                if progress?.phase == .verifying {
                    Text("Checking the file’s checksum…").font(.callout).foregroundStyle(.secondary)
                } else if let progress, progress.receivedBytes > 0 {
                    Text("\(progress.receivedBytes.formatted(.byteCount(style: .file))) received")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ModelProgressBar: View {
    let fraction: Double

    var body: some View {
        Capsule().fill(Color.secondary.opacity(0.15))
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(WorkspaceStyle.models.base)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                        .motion(Motion.standard, value: fraction)
                }
            }
    }
}

struct ModelDownloadsEmpty: View {
    let browse: () -> Void

    var body: some View {
        EmptyState(symbol: "arrow.down.circle", title: String(localized: "Nothing downloading"),
                   message: String(localized: "Pick a model under All and choose Download."),
                   action: (String(localized: "Show All Models"), false, browse))
            .frame(minHeight: 300)
    }
}
