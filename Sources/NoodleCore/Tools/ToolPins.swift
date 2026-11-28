import Foundation

/// The Docker client tools Noodle can fetch on first use. Pinned versions and SHA-256 sums; keep in
/// sync with scripts/fetch-tools.sh (`tests/tools.sh` checks that they agree). Nothing is installed
/// globally: files live under `<root>/tools` and are only linked into a Docker config on request.
public struct ToolPin: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case tarball(member: String), plugin, binary }
    public let name: String          // file name in tools (docker) or cli-plugins
    public let version: String
    public let sha256: String        // of the downloaded file (the tarball for docker)
    public let file: String          // download file name, appended to the base URL
    public let upstream: String
    public let kind: Kind

    public func url(mirror: String?) -> String {
        (mirror.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } ?? upstream) + "/" + file
    }
}

public enum Tools {
    public static let modelVersion = "1.2.9"
    public static let modelPlugin = "docker-model"
    public static var pluginNames: [String] {
        pins.filter { $0.kind == .plugin }.map(\.name)
    }

    public static let pins: [ToolPin] = [
        ToolPin(name: "docker", version: "29.9.3",
                sha256: "79145e169bca0b9571d02de8e1cd311a36e0e8fdb4599b6661a87b1bb3afbe13",
                file: "docker-29.9.3.tgz", upstream: "https://download.docker.com/mac/static/stable/aarch64",
                kind: .tarball(member: "docker/docker")),
        ToolPin(name: "docker-compose", version: "5.7.1",
                sha256: "5a9aa8b5fb5b1e3cd83f39c80e570ae30aafd74cd9b47264fbe4ff7e6e6251ca",
                file: "docker-compose-darwin-aarch64", upstream: "https://github.com/docker/compose/releases/download/v5.7.1",
                kind: .plugin),
        ToolPin(name: "docker-buildx", version: "0.39.0",
                sha256: "0190e4b9c85510974290f9a597e86c4d8200be782aeaa3df7d756ab4423d6b2d",
                file: "buildx-v0.39.0.darwin-arm64", upstream: "https://github.com/docker/buildx/releases/download/v0.39.0",
                kind: .plugin),
        // Official Docker Desktop 4.99.0 arm64 CLI, signed by Docker (Team 9BNSXJN65R).
        // OCI module byte equivalence has not been exercised; every extracted binary must match.
        // `file` is the raw binary's mirror label; upstream is resolved as OCI, never as a direct URL.
        ToolPin(name: "docker-model", version: "1.2.9",
                sha256: "347a6bdf2edc4abcd2ce9d738122e3ed9d800c089e83aa6affe4e30809dced8a",
                file: "docker-model-v1.2.9.darwin-arm64", upstream: "https://registry-1.docker.io/v2/docker/docker-model-cli-desktop-module",
                kind: .plugin),
    ]

    /// Optional tools, fetched only when named (`noodle tools install act`) and linked into
    /// ~/.local/bin when that name is free. Never part of a bare `noodle tools install`; setup names kubectl only.
    public static let extras: [ToolPin] = [
        ToolPin(name: "act", version: "0.2.98",
                sha256: "14477d7e076b12a885c54301beff2b524a905e4238a2b3ec9b3d1fd0efdc100f",
                file: "act_Darwin_arm64.tar.gz", upstream: "https://github.com/nektos/act/releases/download/v0.2.98",
                kind: .tarball(member: "act")),
        // Setup fetches this one when no kubectl is on PATH. Hash is the upstream kubectl.sha256 asset.
        ToolPin(name: "kubectl", version: "1.37.2",
                sha256: "55701af0d51815ee335f240e48acf0959c3c23017ed3fa816e880c4a92bae581",
                file: "kubectl", upstream: "https://dl.k8s.io/release/v1.37.2/bin/darwin/arm64",
                kind: .binary),
    ]

    public static func directory(_ paths: NoodlePaths) -> URL { paths.root.appendingPathComponent("tools", isDirectory: true) }
    public static func docker(_ paths: NoodlePaths) -> URL { directory(paths).appendingPathComponent("docker") }
    public static func pluginDirectory(_ paths: NoodlePaths) -> URL { directory(paths).appendingPathComponent("cli-plugins", isDirectory: true) }

    /// Plugins to expose in `<dockerConfig>/cli-plugins`. A name that already exists there (Docker
    /// Desktop's links, a user's own binary) is left alone; only absent names get a link.
    public static func linksToCreate(existing: Set<String>) -> [String] {
        pluginNames.filter { !existing.contains($0) }
    }
}
