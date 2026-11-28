import Foundation

/// One bounded memory reading for a container, for those past the first sixteen streams. The daemon serves
/// `stats?stream=false&one-shot=true`, a single document, so nothing stays open between readings.
enum OverviewMemory {
    static func ids(_ containers: [ContainerSummary]) -> [String] {
        containers.filter { $0.state == "running" || $0.state == "paused" }.map(\.id)
    }

    static func sampler(service: any DockerService, socketPath: String, demo: Bool) -> @Sendable (String) async -> Int? {
        if demo {
            // The demo service has no socket: its first streamed sample is the reading.
            return { id in
                guard let stream = try? await service.stats(id) else { return nil }
                do { for try await sample in stream { return sample.memoryBytes } } catch {}
                return nil
            }
        }
        return { id in
            let target = "/containers/\(id)/stats?stream=false&one-shot=true"
            guard let r = try? await DockerSocket(path: socketPath).request("GET", target, timeout: 5), r.status < 300 else { return nil }
            return bytes(r.body)
        }
    }

    static func bytes(_ body: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let memory = object["memory_stats"] as? [String: Any], memory["usage"] is NSNumber else { return nil }
        return DockerAPI.sample(object, index: 1).memoryBytes
    }
}
