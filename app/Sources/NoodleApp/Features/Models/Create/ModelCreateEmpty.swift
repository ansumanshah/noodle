import NoodleCore
import SwiftUI

/// No image, speech or video model yet: offer the catalog ones with their size and whether they fit this Mac.
struct ModelCreateEmpty: View {
    let create: ModelCreateStore
    let openLibrary: () -> Void

    private var models: ModelsPageStore { create.models }

    var body: some View {
        VStack(spacing: Space.m) {
            Spacer(minLength: 0)
            Image(systemName: "wand.and.stars").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
            Text("Make pictures, voices and clips").font(.title3.weight(.semibold))
            Text("Download a model to start. Everything runs on this Mac.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(spacing: Space.s) {
                ForEach(create.catalog.filter(\.downloadable)) { model in row(model) }
            }
            .frame(maxWidth: Control.height * 16)
            Button("Open Library", action: openLibrary).buttonStyle(.neutralAction)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .padding(Space.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ model: LocalModel) -> some View {
        let fit = ModelLibraryPolicy.fit(model)
        let downloading = models.activity == .command(.download(model.id))
        return HStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(model.name).font(.callout.weight(.medium))
                (Text(ModelLibraryPolicy.size(model.bytes))
                    + (fit.map { Text(" · ") + Text($0.label).foregroundStyle($0 == .good ? Color.secondary : Status.warning) } ?? Text("")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.s)
            if downloading {
                ProgressView(value: models.downloadProgress.map { Double($0.receivedBytes) / Double(max(1, $0.totalBytes)) } ?? 0)
                    .frame(width: Control.height * 3)
            } else {
                Button("Download") { Task { await models.perform(.download(model.id)) } }
                    .buttonStyle(.primaryAction)
                    .disabled(models.busy || fit == .tooBig)
                    .help(fit == .tooBig ? String(localized: "This model needs more memory than this Mac has.") : "")
            }
        }
        .cardSurface(padding: Space.m)
        .accessibilityElement(children: .combine)
    }
}
