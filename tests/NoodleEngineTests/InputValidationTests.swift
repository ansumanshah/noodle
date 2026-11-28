import Foundation
import Testing
@testable import NoodleImages
@testable import NoodleEngine

@Suite struct InputValidationTests {
    private func archive(size: [UInt8], type: UInt8 = 48, payload: Data = Data()) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-tar-\(UUID().uuidString)")
        var header = Data(repeating: 0, count: 512)
        header[0] = 120
        header[156] = type
        header.replaceSubrange(124..<(124 + size.count), with: size)
        try (header + payload).write(to: url)
        return url
    }

    @Test(arguments: [Array("-2000".utf8), Array("bogus".utf8),
                      [0x80, 0, 0, 0, 0x80, 0, 0, 0, 0, 0, 0, 0],
                      [0x81, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                      Array("00000001000".utf8)])
    func hostileArchiveSizesAreRejected(size: [UInt8]) throws {
        let url = try archive(size: size)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try TarReader(url: url)
        #expect(throws: ImageError.self) { try reader.next() }
    }

    @Test(arguments: ["9223372036854775807", "-1", "invalid"])
    func hostilePAXSizesAreRejected(size: String) throws {
        let metadata = Data("30 size=\(size)\n".utf8)
        var payload = metadata + Data(repeating: 0, count: 512 - metadata.count)
        var file = Data(repeating: 0, count: 512)
        file[0] = 120; file[156] = 48
        payload.append(file)
        let url = try archive(size: Array(String(metadata.count, radix: 8).utf8), type: 120, payload: payload)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try TarReader(url: url)
        #expect(throws: ImageError.self) { try reader.next() }
    }

    @Test(arguments: ["", ":", ":ro", "source:", "source:other", "source:ro:extra"])
    func malformedVolumesFromAreRejected(value: String) async {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        var host = HostConfig(); host.VolumesFrom = [value]
        await #expect(throws: EngineError.self) {
            try await engine.resolveMounts(hc: host, cfg: ContainerConfig(), imageVolumes: [])
        }
    }

    @Test(arguments: ["9223372036854775807g", "-1", "-1m", "bogus", "1gg"])
    func malformedTmpfsSizesAreRejected(value: String) async {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        var host = HostConfig(); host.Tmpfs = ["/scratch": "size=\(value)"]
        await #expect(throws: EngineError.self) {
            try await engine.resolveMounts(hc: host, cfg: ContainerConfig(), imageVolumes: [])
        }
    }

    @Test func normalTmpfsSizesKeepTheirMeaning() async throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        for (value, bytes) in [("64m", Int64(64 << 20)), ("1024", 1024), ("0", 0)] {
            var host = HostConfig(); host.Tmpfs = ["/scratch": "size=\(value)"]
            let result = try await engine.resolveMounts(hc: host, cfg: ContainerConfig(), imageVolumes: [])
            #expect(result.guest.first?.tmpfsSize == bytes)
        }
    }
}
