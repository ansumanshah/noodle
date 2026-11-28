import Foundation
import NIOHTTP1
import NoodleCore
import NoodleEngine
import Testing
@testable import NoodleAPI

@Suite("ModelRunnerAccess")
struct ModelRunnerAccessTests {
    private let access = ModelRunnerAccess(key: String(repeating: "a", count: 64), port: 52434)

    @Test func composeCapabilityIsAnOpenAIBaseURL() throws {
        let base = access.connection.host
        #expect(base.hasPrefix("http://host.docker.internal:52434/model-runner/"))
        #expect(try access.target(base + "/v1/chat/completions", method: .POST, loopback: false) == "/engines/v1/chat/completions")
        #expect(try access.target(access.prefix + "/v1/models", method: .GET, loopback: false) == "/engines/v1/models")
        #expect(access.connection.environment["HTTP_PROXY"] == "http://127.0.0.1:52434")
        #expect(access.connection.environment["NO_PROXY"]?.contains("host.docker.internal") == false)
        let decoded = try JSONDecoder().decode(ModelRunnerConnection.self, from: JSONEncoder().encode(access.connection))
        #expect(decoded.host == base)
    }

    @Test(arguments: ["/models/create", "/engines/_configure", "/engines/unload", "/containers/create", "/logs"])
    func workloadCannotManageModels(path: String) throws {
        do {
            _ = try access.target(access.prefix + path, method: .POST, loopback: false)
            Issue.record("Workload management was accepted")
        } catch let error as DockerModelRunnerError { #expect(error.status == 403) }
        #expect(try access.target(access.prefix + path, method: .POST, loopback: true) == path)
    }

    @Test(arguments: ["/v1/models", "/model-runner/wrong/v1/models", "/model-runner/aaaaaaaa/v1/models"])
    func keyIsRequiredEvenForMetadata(path: String) throws {
        do {
            _ = try access.target(path, method: .GET, loopback: true)
            Issue.record("A request without the URL key was accepted")
        } catch let error as DockerModelRunnerError { #expect(error.status == 401) }
    }

    @Test(arguments: ["http://example.com:52434", "https://host.docker.internal:52434", "http://host.docker.internal:80", "http://user@host.docker.internal:52434"])
    func proxyCannotReachAnotherAuthority(authority: String) throws {
        do {
            _ = try access.target(authority + access.prefix + "/models", method: .GET, loopback: true)
            Issue.record("A different proxy authority was accepted")
        } catch let error as DockerModelRunnerError { #expect(error.status == 400) }
    }

    @Test func workloadCannotEscapeTheInferenceRoutes() throws {
        for path in ["/v1/models/../../models/create", "/v1/models/%2e%2e/containers", "/v1/models/name%2F..%2Fcontainers",
                     "/v1/models/%2E%2E/containers", "/v1/models/.%2e/containers", "/v1/models/%2e./containers"] {
            #expect(throws: DockerModelRunnerError.self) { try access.target(access.prefix + path, method: .GET, loopback: false) }
            #expect(throws: DockerModelRunnerError.self) {
                try access.target("http://host.docker.internal:52434" + access.prefix + path, method: .GET, loopback: false)
            }
        }
    }
}
