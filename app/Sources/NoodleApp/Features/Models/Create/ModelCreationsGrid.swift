import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Results, newest first. Each card has Save, Copy, Show in Finder and Delete.
struct ModelCreationsGrid: View {
    let creations: ModelCreations
    @State private var player = ModelCreationPlayer()

    var body: some View {
        if creations.items.isEmpty {
            Text("What you make shows up here, saved on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, Space.page)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Control.height * 7), spacing: Space.m)], spacing: Space.m) {
                ForEach(creations.items) { item in
                    ModelCreationCard(creation: item, url: creations.url(for: item), player: player) {
                        if player.playing == item.id { player.stop() }
                        try? creations.delete(item.id)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
    }
}

/// Inline speech playback. One clip plays at a time.
@MainActor @Observable
final class ModelCreationPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playing: UUID?
    @ObservationIgnored private var audio: AVAudioPlayer?

    func toggle(_ id: UUID, url: URL) {
        if playing == id { stop(); return }
        audio = try? AVAudioPlayer(contentsOf: url)
        audio?.delegate = self
        guard let audio, audio.play() else { stop(); return }
        playing = id
    }

    func stop() { audio?.stop(); audio = nil; playing = nil }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in if let audio, ObjectIdentifier(audio) == finished { stop() } }
    }
}

struct ModelCreationCard: View {
    let creation: ModelCreation
    let url: URL
    let player: ModelCreationPlayer
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            media
                .frame(maxWidth: .infinity)
                .frame(height: Control.height * 6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            Text(creation.prompt).font(.callout).lineLimit(2).help(creation.prompt)
            HStack(spacing: Space.xs) {
                Button("Save…", systemImage: "square.and.arrow.down", action: save)
                Button("Copy", systemImage: "doc.on.doc", action: copy)
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Spacer(minLength: 0)
                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            }
            .labelStyle(.iconOnly).buttonStyle(.iconAction)
        }
        .cardSurface(padding: Space.m)
        .contextMenu {
            Button("Save…", action: save)
            Button("Copy", action: copy)
            Button("Delete", role: .destructive, action: delete)
        }
    }

    @ViewBuilder private var media: some View {
        switch creation.kind {
        case .image:
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).accessibilityLabel(Text(creation.prompt))
            }
        case .speech:
            let playing = player.playing == creation.id
            Button(playing ? "Stop" : "Play", systemImage: playing ? "stop.circle.fill" : "play.circle.fill") {
                player.toggle(creation.id, url: url)
            }
            .labelStyle(.iconOnly).buttonStyle(.plain).font(.largeTitle).foregroundStyle(.tint)
            .contentTransition(.symbolEffect(.replace))
        case .video:
            VideoPlayer(player: AVPlayer(url: url))
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Noodle " + creation.created.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: ".") + "." + url.pathExtension
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: url, to: target)
    }

    private func copy() {
        let board = NSPasteboard.general
        board.clearContents()
        if creation.kind == .image, let image = NSImage(contentsOf: url) { board.writeObjects([url as NSURL, image]) } else { board.writeObjects([url as NSURL]) }
    }
}
