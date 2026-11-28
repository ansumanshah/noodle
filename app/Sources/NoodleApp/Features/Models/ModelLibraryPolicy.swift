import Foundation
import NoodleCore

enum ModelLibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case installed = "On this Mac"
    case available = "Available"
    case downloading = "Downloading"

    var id: Self { self }
}

enum ModelLibraryPolicy {
    /// Fallback for memory tiers the bench has not measured.
    static let recommendedModelID = "qwen3.5-2b"

    /// Measured winners as (minimum GiB, catalog id), largest tier first.
    /// Measured on an M4 with 16 GB: Qwen 3.5 4B passed 12/12 helper checks with a 3.9 GB peak and no memory refusals; 2B passed 11/12;
    /// 9B, Gemma 4 E4B and Nemotron 3.5 Bolt E4B peaked over the 6 GB limit. 4B decodes about 2.4x slower than 2B.
    /// shortcut: only a 16 GB Mac was benched, so 24 GB and up reuse the 16 GB pick; add rows after benching them.
    static let measuredWinners: [(minGiB: UInt64, id: String)] = [(16, "qwen3.5-4b")]

    static func preferredModelID(totalMemory: UInt64) -> String {
        measuredWinners.first { totalMemory >= $0.minGiB << 30 }?.id ?? recommendedModelID
    }

    /// Judged from this Mac's installed memory, so it never changes with what is open. A model already on this Mac
    /// never reads "too big": it is there, so the worst honest label is tight.
    static func fit(_ model: LocalModel, totalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> ModelMemoryFit? {
        guard model.bytes > 0 else { return nil }
        let fit = ModelMemoryFit(modelBytes: model.bytes, totalMemory: totalMemory)
        return model.installed && fit == .tooBig ? .tight : fit
    }

    /// Only when nothing is installed: the preferred model for this memory tier if the catalog has it, else the smallest that is not too big.
    static func recommended(_ models: [LocalModel], totalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> LocalModel? {
        guard !models.contains(where: \.installed) else { return nil }
        let downloadable = models.filter(\.downloadable)
        if let pinned = downloadable.first(where: { $0.id == preferredModelID(totalMemory: totalMemory) }) { return pinned }
        return downloadable.filter { fit($0, totalMemory: totalMemory) != .tooBig }.min { $0.bytes < $1.bytes }
    }

    enum State: String, Equatable {
        case available = "Available"
        case installed = "Installed"
        case running = "Running"
        case starting = "Starting"
        case stopping = "Stopping"
        case downloading = "Downloading"
        case verifying = "Verifying"
        case removing = "Removing"
        case importNeeded = "Import needed"
    }

    /// `downloading` is the model a download is running for; the Downloading filter shows only it.
    static func models(_ models: [LocalModel], query: String, filter: ModelLibraryFilter,
                       downloading: String? = nil) -> [LocalModel] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return models.filter { model in
            switch filter {
            case .all: break
            case .installed: guard model.installed else { return false }
            case .available: guard !model.installed, model.downloadable else { return false }
            case .downloading: guard model.id == downloading else { return false }
            }
            if terms.isEmpty { return true }
            let format = model.backend == .mlx ? "MLX" : "GGUF"
            let origin = model.downloadable ? "" : "imported"
            let searchable = "\(model.name) \(model.id) \(model.backend.displayName) \(format) \(origin)"
            return terms.allSatisfy { searchable.localizedStandardContains($0) }
        }
    }

    static func state(model: LocalModel, status: LocalModelStatus, activity: ModelsPageStore.Activity?,
                      progress: LocalModelPullProgress?) -> State {
        switch activity {
        case .command(.download(let id)) where id == model.id:
            return progress?.phase == .verifying ? .verifying : .downloading
        case .command(.start(let id)) where id == model.id: return .starting
        case .command(.stop) where status.model == model.id: return .stopping
        case .command(.remove(let id)) where id == model.id: return .removing
        default: break
        }
        if status.model == model.id {
            if status.phase == .ready { return .running }
            if status.phase == .starting { return .starting }
        }
        if model.installed { return .installed }
        return model.downloadable ? .available : .importNeeded
    }

    static func transferFraction(_ progress: LocalModelPullProgress) -> Double? {
        if progress.phase == .installed { return 1 }
        guard progress.phase == .downloading, progress.totalBytes > 0 else { return nil }
        // File receipt is not completion. The checksum must pass before showing 100%.
        return min(Double(progress.receivedBytes) / Double(progress.totalBytes), 0.99)
    }

    static func downloadingID(_ activity: ModelsPageStore.Activity?) -> String? {
        if case .command(.download(let id)) = activity { return id }
        return nil
    }

    /// The sidebar's Library badge: whole percent while bytes arrive, an arrow while preparing or verifying.
    static func badge(_ progress: LocalModelPullProgress?) -> String? {
        guard let progress else { return nil }
        guard let fraction = transferFraction(progress), progress.phase == .downloading else { return "↓" }
        return "↓ " + fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static func size(_ bytes: UInt64) -> String {
        bytes == 0 ? "Size unavailable" : bytes.formatted(.byteCount(style: .file))
    }
}
