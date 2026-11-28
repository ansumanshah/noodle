import Foundation
import NoodleCore
import Testing
@testable import NoodleEngine

/// `docker run --gpus`: Docker's own error by default, the model endpoint only for the named driver.
@Suite struct GPURequestTests {
    private func hostConfig(_ requests: String) throws -> HostConfig {
        try JSONDecoder().decode(HostConfig.self, from: Data(#"{"DeviceRequests":\#(requests)}"#.utf8))
    }

    @Test func plainGpusFailsWithDockersError() throws {
        // The body the docker CLI sends for `--gpus all`.
        let hc = try hostConfig(#"[{"Driver":"","Count":-1,"DeviceIDs":null,"Capabilities":[["gpu"]],"Options":{}}]"#)
        do {
            try Engine.refuseUnsupported(hc)
            Issue.record("--gpus all was accepted")
        } catch EngineError.internalError(let message) {
            #expect(message.hasPrefix(#"could not select device driver "" with capabilities: [[gpu]]"#))
            #expect(message.contains("--gpus driver=noodle-models"))
        }
    }

    @Test func unknownDriverFailsAndNamesIt() throws {
        let hc = try hostConfig(#"[{"Driver":"noodle-models"},{"Driver":"nvidia","Capabilities":[["gpu","compute"],["utility"]]}]"#)
        do {
            try Engine.refuseUnsupported(hc)
            Issue.record("an unknown driver was accepted")
        } catch EngineError.internalError(let message) {
            #expect(message.hasPrefix(#"could not select device driver "nvidia" with capabilities: [[gpu compute] [utility]]"#))
        }
    }

    @Test func modelsDriverAndNoRequestAreAccepted() throws {
        try Engine.refuseUnsupported(try hostConfig(#"[{"Driver":"noodle-models","Count":1,"Capabilities":[["gpu"]]}]"#))
        try Engine.refuseUnsupported(HostConfig())
    }

    @Test func endpointIsAddedWithoutReplacingWhatTheContainerSets() {
        let connection = ModelRunnerConnection(host: "http://host.docker.internal:52434/model-runner/k", proxy: "http://127.0.0.1:52434")
        #expect(connection.containerEnvironment(adding: ["A=1"]) == [
            "A=1", "MODEL_RUNNER_HOST=http://host.docker.internal:52434/model-runner/k",
            "OPENAI_BASE_URL=http://host.docker.internal:52434/model-runner/k/engines/v1", "OPENAI_API_KEY=noodle",
        ])
        let kept = connection.containerEnvironment(adding: ["OPENAI_API_KEY=mine", "OPENAI_BASE_URL"])
        #expect(kept == ["OPENAI_API_KEY=mine", "OPENAI_BASE_URL", "MODEL_RUNNER_HOST=http://host.docker.internal:52434/model-runner/k"])
    }
}
