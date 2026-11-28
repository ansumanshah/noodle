import Foundation
import Testing
@testable import NoodleAPI
@testable import NoodleEngine

/// Response shapes Testcontainers (Java, Go, Node) and docker-java read from the daemon.
@Suite struct ClientCompatibilityTests {
    private func json<T: Encodable>(_ v: T) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as? [String: Any])
    }

    @Test func versionReportsCurrentAPIAndPlatform() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let v = try json(await Engine(paths: paths).version())
        for key in ["Version", "ApiVersion", "MinAPIVersion", "Os", "Arch", "KernelVersion", "GitCommit", "GoVersion", "BuildTime"] {
            #expect((v[key] as? String)?.isEmpty == false, "missing /version \(key)")
        }
        #expect(v["ApiVersion"] as? String == APIInfo.apiVersion)
        #expect(v["MinAPIVersion"] as? String == APIInfo.minAPIVersion)
        #expect(v["Os"] as? String == "linux" && v["Arch"] as? String == "arm64")
    }

    @Test func infoCarriesTheFieldsClientsCheck() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let i = try json(await Engine(paths: paths).info())
        for key in ["ID", "ServerVersion", "OperatingSystem", "OSType", "Architecture", "KernelVersion", "Name",
                    "IndexServerAddress", "DockerRootDir", "Driver", "CgroupVersion"] {
            #expect((i[key] as? String)?.isEmpty == false, "missing /info \(key)")
        }
        #expect(i["OSType"] as? String == "linux")
        #expect((i["NCPU"] as? Int ?? 0) > 0 && (i["MemTotal"] as? Int ?? 0) > 0)
    }

    @Test func versionedPathsUpToCurrentAreAccepted() {
        for v in ["1.24", "1.40", "1.44", "1.51", APIInfo.apiVersion] {
            #expect(URLParts.isVersionSegment("v" + v))
            #expect(Request.compare(v, APIInfo.apiVersion) <= 0 && Request.compare(v, APIInfo.minAPIVersion) >= 0)
        }
        #expect(Request.compare("1.100", APIInfo.apiVersion) > 0)
        #expect(Request.compare("1.23", APIInfo.minAPIVersion) < 0)
    }

    @Test func inspectCarriesPortsAndStateKeys() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        try await engine.start()
        _ = try await makeImage(engine)
        let req = try JSONDecoder().decode(ContainerCreateRequest.self, from: Data(#"{"Image":"tiny","ExposedPorts":{"8080/tcp":{}}}"#.utf8))
        let (id, _) = try await engine.createContainer(name: nil, request: req)
        let c = try json(await engine.inspectContainer(id))
        let ns = try #require(c["NetworkSettings"] as? [String: Any])
        #expect(ns["Ports"] is [String: Any])
        #expect(ns["Networks"] is [String: Any])
        let state = try #require(c["State"] as? [String: Any])
        for key in ["Status", "Running", "ExitCode"] { #expect(state[key] != nil, "missing State.\(key)") }
        await engine.shutdown()
    }
}
