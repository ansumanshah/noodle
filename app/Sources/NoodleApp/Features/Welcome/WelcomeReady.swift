import NoodleCore
import SwiftUI

/// Screen 2: one column per chosen product, each with one optional button.
struct WelcomeReadyCard: View {
    let flow: WelcomeFlow

    var body: some View {
        VStack(spacing: Space.m) {
            WelcomeColumns(products: flow.products) { product in
                switch product {
                case .models: WelcomeModelColumn(flow: flow)
                case .containers:
                    WelcomeColumn(product: product, title: String(localized: "Docker tools"),
                                  status: flow.isDone(product) ? String(localized: "Set up") : String(localized: "Not set up")) {
                        Text("Use docker and Compose with Noodle.")
                    } action: {
                        step(product, button: String(localized: "Connect…"), done: String(localized: "Connected"))
                    }
                case .runners:
                    WelcomeColumn(product: product, title: String(localized: "Your first repo"),
                                  status: flow.source.repoCount == 0 ? String(localized: "No repos") : Fmt.count(flow.source.repoCount, "repo")) {
                        Text("Its GitHub Actions jobs run here.")
                    } action: {
                        step(product, button: String(localized: "Add Repo…"), done: String(localized: "Added"))
                    }
                }
            }
            HStack(spacing: Space.xs) {
                Text("Prefer the terminal?").font(.subheadline).foregroundStyle(.secondary)
                SetupCode(text: "noodle setup")
            }
        }
    }

    @ViewBuilder private func step(_ product: WelcomeProduct, button: String, done: String) -> some View {
        if flow.isDone(product) {
            WelcomeDoneCapsule(text: done).transition(.scale(scale: 0.9).combined(with: .opacity))
        } else {
            Button(button) { flow.act(product) }.buttonStyle(.neutralAction)
                .transition(.opacity)
        }
    }
}

/// The starter model: its real name and size, live progress while it downloads, Ready once it is on this Mac.
struct WelcomeModelColumn: View {
    let flow: WelcomeFlow
    private var source: any WelcomeSource { flow.source }

    var body: some View {
        WelcomeColumn(product: .models, title: String(localized: "Starter model"), status: status) {
            detail
        } action: {
            if source.modelReady {
                WelcomeDoneCapsule(text: String(localized: "Ready")).transition(.scale(scale: 0.9).combined(with: .opacity))
            } else if let progress = source.progress {
                progressView(progress).transition(.opacity)
            } else {
                Button { flow.act(.models) } label: { Label("Download", systemImage: "arrow.down") }
                    .buttonStyle(.primaryAction).disabled(source.starter == nil)
                    .transition(.opacity)
            }
        }
        .motion(Motion.snappy, value: source.modelReady)
        .motion(Motion.snappy, value: source.downloading)
    }

    private var status: String {
        if source.modelReady { return String(localized: "On this Mac") }
        if let progress = source.progress { return progress.phase == .downloading ? String(localized: "Downloading") : String(localized: "Checking") }
        if source.modelProblem != nil { return String(localized: "Didn’t finish") }
        return source.starter == nil ? String(localized: "Looking…") : String(localized: "Not installed")
    }

    private var detail: Text {
        if let problem = source.modelProblem, !source.downloading { return Text(problem) }
        guard let model = source.starter else { return Text("Finding a model that suits this Mac.") }
        if let progress = source.progress, progress.totalBytes > 0 {
            return Text("\(progress.receivedBytes.formatted(.byteCount(style: .file))) of \(progress.totalBytes.formatted(.byteCount(style: .file)))")
        }
        return Text("\(model.name) · \(ModelLibraryPolicy.size(model.bytes))")
    }

    private func progressView(_ progress: LocalModelPullProgress) -> some View {
        let fraction = ModelLibraryPolicy.transferFraction(progress) ?? 0.99
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        return HStack(spacing: Space.s) {
            ModelProgressBar(fraction: fraction)
            Text(percent).font(.callout.monospacedDigit().weight(.semibold))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Downloading the starter model"))
        .accessibilityValue(percent)
    }
}
