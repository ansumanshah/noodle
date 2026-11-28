import Foundation
import NoodleCore

private struct ModelToolDownloadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct ModelToolDescriptor: Decodable {
    struct Platform: Decodable { let os: String; let architecture: String }
    let digest: String
    let size: Int64
    let platform: Platform?
}

private struct ModelToolManifest: Decodable {
    let manifests: [ModelToolDescriptor]?
    let layers: [ModelToolDescriptor]?
}

/// Fetch Docker's own module without linking the image registry client or starting a daemon.
/// Descriptor hashes authenticate downloaded archives; toolsInstall checks the final binary pin.
func downloadModelTool(pin: ToolPin, to output: URL, work: URL) throws {
    let fm = FileManager.default
    let desktop = URL(fileURLWithPath: "/Applications/Docker.app/Contents/Resources/cli-plugins/docker-model")
    if toolFileOK(desktop, sha: pin.sha256) {
        try fm.copyItem(at: desktop, to: output)
        return
    }
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: work.path)
    let tokenFile = work.appendingPathComponent("model-token.json")
    let headerFile = work.appendingPathComponent("model-auth.header")
    defer { try? fm.removeItem(at: tokenFile); try? fm.removeItem(at: headerFile) }
    // Create private files before curl opens them; the token never appears in argv or logs.
    for file in [tokenFile, headerFile] {
        guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ModelToolDownloadError(message: "cannot create private registry authentication file")
        }
    }
    func fetch(_ url: String, to file: URL, limit: Int64, authenticated: Bool = true) throws {
        var arguments = ["--fail", "--silent", "--show-error", "--location", "--proto", "=https",
                         "--proto-redir", "=https", "--connect-timeout", "15", "--max-time", "180", "--retry", "3",
                         "--max-filesize", String(limit), "--output", file.path]
        if authenticated {
            arguments += ["--header", "@" + headerFile.path, "--header",
                          "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"]
        }
        let result = try downloadTool(arguments + [url])
        if let signal = result.cancelledSignal {
            try? fm.removeItem(at: work)
            exit(128 + signal)
        }
        guard result.code == 0 else { throw ModelToolDownloadError(message: "Docker module download failed (curl \(result.code))") }
        let size = (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size >= 0, size <= limit else { throw ModelToolDownloadError(message: "Docker module response exceeds its size limit") }
    }
    try fetch("https://auth.docker.io/token?service=registry.docker.io&scope=repository:docker/docker-model-cli-desktop-module:pull",
              to: tokenFile, limit: 1_048_576, authenticated: false)
    struct Token: Decodable { let token: String }
    let token = try JSONDecoder().decode(Token.self, from: Data(contentsOf: tokenFile)).token
    guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else {
        throw ModelToolDownloadError(message: "invalid Docker registry token")
    }
    let header = try FileHandle(forWritingTo: headerFile)
    try header.write(contentsOf: Data("Authorization: Bearer \(token)\n".utf8))
    try header.close()
    let registry = "https://registry-1.docker.io/v2/docker/docker-model-cli-desktop-module"
    let indexFile = work.appendingPathComponent("model-index.json")
    try fetch(registry + "/manifests/v" + pin.version, to: indexFile, limit: 4_194_304)
    let decoder = JSONDecoder()
    let index = try decoder.decode(ModelToolManifest.self, from: Data(contentsOf: indexFile))
    let matches = (index.manifests ?? []).filter { $0.platform?.os == "darwin" && $0.platform?.architecture == "arm64" }
    guard matches.count == 1 else { throw ModelToolDownloadError(message: "Docker module must contain one darwin/arm64 manifest") }
    func fetchDescriptor(_ descriptor: ModelToolDescriptor, path: String, to file: URL, limit: Int64) throws {
        let hash = descriptor.digest.dropFirst(7)
        guard descriptor.digest.hasPrefix("sha256:"), hash.count == 64,
              hash.allSatisfy({ "0123456789abcdef".contains($0) }), descriptor.size > 0, descriptor.size <= limit else {
            throw ModelToolDownloadError(message: "invalid Docker module descriptor")
        }
        try fetch(registry + "/" + path + "/" + descriptor.digest, to: file, limit: descriptor.size)
        let size = (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        guard size == descriptor.size, try Digest.sha256(file: file) == descriptor.digest else {
            throw ModelToolDownloadError(message: "Docker module descriptor SHA-256 or size mismatch")
        }
    }
    let manifestFile = work.appendingPathComponent("model-manifest.json")
    try fetchDescriptor(matches[0], path: "manifests", to: manifestFile, limit: 4_194_304)
    let manifest = try decoder.decode(ModelToolManifest.self, from: Data(contentsOf: manifestFile))
    guard let layers = manifest.layers, !layers.isEmpty, layers.count <= 32 else {
        throw ModelToolDownloadError(message: "invalid Docker module layer count")
    }
    var found = false
    for (number, layer) in layers.enumerated() {
        let archive = work.appendingPathComponent("model-layer-\(number).tar")
        try fetchDescriptor(layer, path: "blobs", to: archive, limit: 134_217_728)
        let listing = try modelToolTar(["-tf", archive.path], limit: 4_194_304)
        let members = String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { $0.split(separator: "/").last == "docker-model" }
        for member in members {
            let parts = member.split(separator: "/", omittingEmptySubsequences: false)
            guard !found, !member.hasPrefix("/"), !member.contains("\\"), !member.contains("\r"),
                  parts.allSatisfy({ !$0.isEmpty && $0 != ".." }) else {
                throw ModelToolDownloadError(message: "ambiguous or unsafe docker-model archive member")
            }
            let attributes = try modelToolTar(["-tvf", archive.path, "--", member], limit: 65_536)
            guard attributes.first == UInt8(ascii: "-") else {
                throw ModelToolDownloadError(message: "docker-model archive member is not a regular file")
            }
            _ = try modelToolTar(["-xOf", archive.path, "--", member], limit: 134_217_728, output: output)
            found = true
        }
        try fm.removeItem(at: archive)
    }
    guard found else { throw ModelToolDownloadError(message: "Docker module contains no docker-model binary") }
}

/// Stream one archive member to a bounded file, never extract paths into the filesystem.
private func modelToolTar(_ arguments: [String], limit: Int, output: URL? = nil) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    var file: FileHandle?
    if let output {
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ModelToolDownloadError(message: "cannot stage docker-model binary")
        }
        file = try FileHandle(forWritingTo: output)
    }
    defer { try? file?.close() }
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        try? pipe.fileHandleForReading.close()
        process.waitUntilExit()
    }
    var data = Data(), count = 0
    while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
        count += chunk.count
        guard count <= limit else { throw ModelToolDownloadError(message: "Docker module archive output exceeds its size limit") }
        if let file { try file.write(contentsOf: chunk) } else { data.append(chunk) }
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ModelToolDownloadError(message: "cannot read Docker module archive") }
    return data
}
