import Foundation
import Testing
@testable import NoodleCore

@Suite struct LocalModelContractTests {
    @Test func existingCatalogJSONKeepsItsGGUFBackend() throws {
        let data = Data(#"{"id":"gemma4","name":"Gemma 4 E2B","bytes":3349516256,"installed":true,"downloadable":true}"#.utf8)
        let model = try JSONDecoder().decode(LocalModel.self, from: data)
        #expect(model.backend == .llamaCPP)
        #expect(model.installed && model.id == "gemma4")
    }

    @Test func mlxBackendSurvivesCatalogRoundTrip() throws {
        let model = LocalModel(id: "qwen3-0.6b-mlx", name: "Qwen 3 0.6B", bytes: 400_000_000,
                               installed: false, downloadable: true, backend: .mlx)
        let decoded = try JSONDecoder().decode(LocalModel.self, from: JSONEncoder().encode(model))
        #expect(decoded.backend == .mlx)
        #expect(!decoded.installed && decoded.bytes == model.bytes)
    }

    @Test func existingEndpointAndStatusRemainDecodable() throws {
        let status = try JSONDecoder().decode(LocalModelStatus.self, from: Data(#"{"phase":"ready","model":"gemma4","baseURL":"http://127.0.0.1:11345/v1"}"#.utf8))
        let endpoint = try JSONDecoder().decode(LocalModelEndpoint.self, from: Data(#"{"model":"gemma4","baseURL":"http://127.0.0.1:11345/v1","apiKey":"fixture"}"#.utf8))
        #expect(status.backend == nil && status.phase == .ready)
        #expect(endpoint.backend == nil && endpoint.apiKey == "fixture")
        #expect(status.namedBaseURL == nil && endpoint.namedBaseURL == nil)
    }

    @Test func namedEndpointPreservesDirectAddressAndCredentials() throws {
        let direct = try #require(URL(string: "http://127.0.0.1:11345/v1"))
        let named = try #require(URL(string: "http://models.noodle.local:8080/v1"))
        let endpoint = LocalModelEndpoint(model: "fixture", baseURL: direct, apiKey: "fixture-key",
                                          backend: .mlx, namedBaseURL: named)
        let decoded = try JSONDecoder().decode(LocalModelEndpoint.self, from: JSONEncoder().encode(endpoint))
        #expect(decoded.baseURL == direct && decoded.namedBaseURL == named)
        #expect(decoded.apiKey == "fixture-key" && decoded.backend == .mlx)

        let status = LocalModelStatus(phase: .ready, model: "fixture", baseURL: direct,
                                      backend: .mlx, namedBaseURL: named)
        let data = try JSONEncoder().encode(status)
        let snapshot = try JSONDecoder().decode(LocalModelStatus.self, from: data)
        #expect(snapshot.baseURL == direct && snapshot.namedBaseURL == named)
        #expect(!String(decoding: data, as: UTF8.self).contains("fixture-key"))
    }

    @Test func unknownBackendIsRejectedInsteadOfLaunchingTheWrongRunner() {
        let data = Data(#"{"id":"other","name":"Other","bytes":1,"installed":true,"downloadable":false,"backend":"unknown"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LocalModel.self, from: data) }
    }
}
