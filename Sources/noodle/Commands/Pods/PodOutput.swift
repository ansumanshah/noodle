import Foundation

func podPrintJSON(_ value: Any) throws {
    out(jsonLine(value))
}

func podPrintTable(_ pods: [Pod]) {
    out("POD ID\tNAME\tSTATE\tMEMBERS\tRUNNING")
    for pod in pods {
        out("\(pod.infra.id.prefix(12))\t\(pod.name)\t\(pod.infra.state)\t\(pod.members.count)\t\(pod.containers.filter(\.running).count)")
    }
}
func podInspect(_ pod: Pod, _ endpoint: EngineEndpoint) throws -> PodJSON {
    var value = pod.summary
    value["infra"] = try endpoint.inspect("containers", pod.infra.id)
    value["members"] = try pod.members.map { try endpoint.inspect("containers", $0.id) }
    return value
}

private func podLogText(_ data: Data, tty: Bool) throws -> String {
    if tty { return String(decoding: data, as: UTF8.self) }
    let bytes = [UInt8](data)
    var offset = 0, decoded = Data()
    while offset < bytes.count {
        guard bytes.count - offset >= 8, [UInt8(1), UInt8(2)].contains(bytes[offset]),
              bytes[(offset + 1)..<(offset + 4)].allSatisfy({ $0 == 0 }) else { throw CLIError("invalid Docker log frame") }
        let length = bytes[(offset + 4)..<(offset + 8)].reduce(0) { ($0 << 8) | Int($1) }
        offset += 8
        guard length <= bytes.count - offset else { throw CLIError("truncated Docker log frame") }
        decoded.append(contentsOf: bytes[offset..<(offset + length)])
        offset += length
    }
    return String(decoding: decoded, as: UTF8.self)
}

func podLogs(_ pod: Pod, _ endpoint: EngineEndpoint, json: Bool) throws {
    var rows: [PodJSON] = []
    for container in pod.containers {
        let config = try endpoint.inspect("containers", container.id)["Config"] as? PodJSON
        let reply = try endpoint.call("GET", podRoute(container) + "/logs?stdout=1&stderr=1&tail=1000")
        let text = try podLogText(reply.body, tty: config?["Tty"] as? Bool ?? false)
        rows.append(["id": container.id, "container": container.name, "logs": text])
    }
    if json { try podPrintJSON(rows); return }
    out("CONTAINER\tLOG")
    for row in rows {
        for line in (row["logs"] as? String ?? "").split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            out("\(row["container"] as? String ?? "")\t\(line)")
        }
    }
}

func podTop(_ pod: Pod, _ endpoint: EngineEndpoint, json: Bool) throws {
    var rows: [PodJSON] = []
    for container in pod.containers where container.running {
        let reply = try endpoint.call("GET", podRoute(container) + "/top")
        guard let top = try JSONSerialization.jsonObject(with: reply.body) as? PodJSON,
              let titles = top["Titles"] as? [String], let processes = top["Processes"] as? [[String]] else {
            throw CLIError("invalid Docker top reply")
        }
        rows.append(["id": container.id, "container": container.name, "titles": titles, "processes": processes])
    }
    if json { try podPrintJSON(rows); return }
    for row in rows {
        out(row["container"] as? String ?? "")
        out((row["titles"] as? [String] ?? []).joined(separator: "\t"))
        for process in row["processes"] as? [[String]] ?? [] { out(process.joined(separator: "\t")) }
    }
}
