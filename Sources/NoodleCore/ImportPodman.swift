import Foundation

/// Runs `bin args` and returns stdout, or nil on a non-zero exit, a launch failure, the deadline or cancellation.
/// A hung child is terminated, then killed. Output is small, so it is read after exit.
public func runBounded(_ bin: String, _ args: [String], timeout: TimeInterval, cancelled: () -> Bool) -> String? {
    let p = Process(), pipe = Pipe(), done = DispatchSemaphore(value: 0)
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = args
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
    p.terminationHandler = { _ in done.signal() }
    guard (try? p.run()) != nil else { return nil }
    let deadline = Date().addingTimeInterval(timeout)
    while done.wait(timeout: .now() + 0.05) == .timedOut {
        guard !cancelled(), Date() < deadline else {
            p.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            return nil
        }
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
}

extension ImportNaming {
    /// Name of the Podman machine that is running, from `podman machine list --format json`.
    /// Podman runs one machine at a time; if the list says otherwise, the default machine wins, then the first.
    public static func runningPodmanMachine(listJSON: Data) -> String? {
        guard let rows = try? JSONSerialization.jsonObject(with: listJSON) as? [[String: Any]] else { return nil }
        let running = rows.filter { $0["Running"] as? Bool == true }
        let pick = running.first { $0["Default"] as? Bool == true } ?? running.first
        guard let name = (pick?["Name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "* ")), !name.isEmpty else { return nil }
        return name
    }

    /// Where a Podman machine publishes its Docker-compatible API socket on this Mac.
    /// `inspectOutput` is the stdout of `podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}'`
    /// (nil when podman is not on PATH or failed). Without a usable answer, the default locations are probed with `exists`.
    public static func podmanSocket(inspectOutput: String?, home: String, tmpDir: String?, exists: (String) -> Bool) -> String? {
        let reported = (inspectOutput ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") }
        if let first = reported.first(where: exists) ?? reported.first { return first }
        let machine = home + "/.local/share/containers/podman/machine"
        var candidates = [machine + "/podman.sock", machine + "/podman-machine-default/podman.sock", machine + "/qemu/podman.sock"]
        if let tmpDir, !tmpDir.isEmpty {
            candidates.append((tmpDir.hasSuffix("/") ? tmpDir : tmpDir + "/") + "podman/podman-machine-default-api.sock")
        }
        return candidates.first(where: exists)
    }
}
