import Foundation

struct CatalogImageLayer: Decodable, Sendable {
    let digest: String
    let size: Int
    let instruction: String

    private static let demoLayers = Data(#"""
    [{"digest":"sha256:4abcf20661432fb2d719aaf90656f55c287f8ca915dc1c92ec14ff61e67fbaf8","size":8400000,"instruction":"ADD alpine-minirootfs-3.22.0-aarch64.tar.gz / # buildkit"},
     {"digest":"sha256:9f1c6e2d7a40b5c81e3d2f6a7b8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708","size":20480,"instruction":"RUN /bin/sh -c apk add --no-cache ca-certificates # buildkit"}]
    """#.utf8)

    static func load(_ id: String, demo: Bool) async -> [CatalogImageLayer]? {
        guard !demo else { return try? JSONDecoder().decode([CatalogImageLayer].self, from: demoLayers) }
        do {
            let data = try await CLI.captured(["image", "layers", id, "--json"], timeout: 15)
            return try JSONDecoder().decode([CatalogImageLayer].self, from: data)
        } catch { return nil }
    }
}
