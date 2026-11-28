import Foundation

extension ModelsPageStore {
    enum Command: Equatable {
        case download(String)
        case start(String)
        case stop
        case remove(String)
        case importWeights(URL, id: String)

        var arguments: [String] {
            switch self {
            case .download(let id): ["pull", id, "--progress-json"]
            case .start(let id): ["serve", id]
            case .stop: ["stop"]
            case .remove(let id): ["rm", id]
            case .importWeights(let url, let id): ["import", url.path, id]
            }
        }

        var timeout: TimeInterval {
            switch self {
            case .download: 950
            case .start: 1020
            case .importWeights: 300
            case .stop, .remove: 60
            }
        }

        var failureTitle: String {
            switch self {
            case .download: "Download failed"
            case .start: "Couldn’t start the model"
            case .stop: "Couldn’t stop the model"
            case .remove: "Couldn’t remove the model"
            case .importWeights: "Couldn’t import the model"
            }
        }

        var retry: Self? {
            switch self {
            case .download, .start, .stop: self
            case .remove, .importWeights: nil
            }
        }
    }
}
