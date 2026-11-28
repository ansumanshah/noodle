import SwiftUI
import Observation
import NoodleCore

enum SetupImportKind: String, CaseIterable {
    case images, volumes, containers

    var flag: String { "--" + rawValue }

    func count(in inventory: ImportInventory) -> Int {
        switch self {
        case .images: inventory.images
        case .volumes: inventory.volumes
        case .containers: inventory.containers
        }
    }

    var title: String {
        switch self {
        case .images: "Tagged images"
        case .volumes: "Volumes"
        case .containers: "Stopped containers"
        }
    }
}
