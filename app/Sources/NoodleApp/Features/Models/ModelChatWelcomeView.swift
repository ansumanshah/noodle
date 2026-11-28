import NoodleCore
import SwiftUI

/// The empty conversation: a greeting over the composer, centred as one group.
struct ModelChatWelcomeView: View {
    let ready: Bool
    let selectedModel: LocalModel?
    let openLibrary: () -> Void
    /// Set only on first run, when no model is installed yet.
    var recommended: LocalModel?
    /// True when at least one model is on this Mac; decides which single instruction the greeting gives.
    var hasInstalled = true
    var downloading = false
    var download: () -> Void = {}

    var body: some View {
        VStack(spacing: Space.s) {
            Text(ready ? "What’s on your mind?" : "Your models. On your Mac.")
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.4)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
            Text(ready ? "Send a message to your local model."
                 : hasInstalled ? "Start a model with the Start button, then say hello."
                 : "Download a model to start chatting.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 400)
            if !ready, let recommended {
                ModelRecommendedCard(model: recommended, downloading: downloading, download: download)
                    .padding(.top, Space.m)
            }
            if !ready {
                Button(action: openLibrary) { Label("Browse Library", systemImage: "square.stack.3d.up.fill") }
                    .buttonStyle(.neutralAction)
                    .padding(.top, Space.m)
            }
        }
        .padding(.horizontal, Space.page)
        .padding(.bottom, Space.page)
        .frame(maxWidth: .infinity)
        .motion(Motion.standard, value: ready)
    }
}

/// First run: one model chosen for this Mac, one button.
private struct ModelRecommendedCard: View {
    let model: LocalModel
    let downloading: Bool
    let download: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name).font(.headline)
                    detail.font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.m)
                Button(action: download) {
                    if downloading {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Downloading…") }
                    } else {
                        Label("Download", systemImage: "arrow.down")
                    }
                }
                .buttonStyle(.primaryAction)
                .disabled(downloading)
            }
            if model.backend == .mlx {
                Text("The first start sets things up. Allow a few GB of free disk space.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .cardSurface(tinted: false)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models-recommended")
    }

    private var detail: Text {
        let size = Text(ModelLibraryPolicy.size(model.bytes))
        guard let fit = ModelLibraryPolicy.fit(model) else { return size }
        return size + Text(" · ") + Text(fit.label)
    }
}

/// Live state of the request in flight, and the last request's numbers as monospaced stat pills.
struct ModelChatGenerationStatus: View {
    let store: ModelsPageStore

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if store.activity == .prompt {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).accessibilityHidden(true)
                        Text(store.response.state == .cancelling ? "Cancelling response…"
                             : store.response.state == .receiving ? "Responding…"
                             : store.waitingForMemory ? "Waiting for memory…" : "Waiting for the model…")
                    }
                } else if store.response.state == .cancelled {
                    Label("Response cancelled", systemImage: "stop.circle")
                } else if store.response.state == .failed {
                    Label("Response interrupted", systemImage: "exclamationmark.circle")
                        .foregroundStyle(Color(nsColor: .systemRed))
                }
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .transition(.opacity)
            Spacer(minLength: 0)
            if store.activity != .prompt, let line = store.generationMetrics?.speedLine {
                Text(line).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 6)
        .motion(Motion.snappy, value: store.activity == .prompt)
    }
}
