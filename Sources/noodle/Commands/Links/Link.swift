import Foundation
import NoodleCore

private let linkUsage = "usage: noodle link CONTAINER[:PORT] [--yes] [--allow-privileged] [--json] | link list [--json] | link stop ID|--all"

private func linkRequest(_ method: String, _ route: String, _ body: [String: Any]? = nil) throws -> Data {
    let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
    let reply: HTTPReply
    do {
        // Creating a link waits for the tunnel, so allow 150 seconds per read.
        reply = try DockerHTTP(socketPath: socketPath, timeout: 150).request(method, route, headers: ["Content-Type": "application/json"], body: .data(payload))
    } catch let error as ImportError where error.exitCode == ExitCode.engineDown {
        throw CLIError.engineDown("cannot reach the Noodle engine; start it with noodle start")
    } catch let error as ImportError where error.timedOut {
        throw CLIError("the Noodle engine did not answer within 150 seconds")
    } catch {
        throw CLIError("the request to the Noodle engine failed: \(error)")
    }
    let response = reply.body, code = reply.status
    guard (200..<300).contains(code) else {
        let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
        throw CLIError(json?["message"] as? String ?? "public link request failed (HTTP \(code))")
    }
    return response
}

func cmdLink(_ args: [String]) {
    // Invoked only as a child of noodled, with a pipe whose EOF revokes the helper's lifetime.
    if args.first == "_supervise" {
        guard env["NOODLE_LINK_SUPERVISOR"] == "1", args.count == 5, isatty(STDIN_FILENO) == 0 else { die(linkUsage, code: 2) }
        linkSupervise(binary: args[1], target: args[2], directory: args[3], sha256: args[4])
    }
    do {
        if args.first == "list" {
            guard args.count == 1 || args == ["list", "--json"] else { throw CLIError.usage(linkUsage) }
            let data = try linkRequest("GET", "/noodle/links")
            if args.contains("--json") { FileHandle.standardOutput.write(data + Data([10])); return }
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CLIError("invalid link list reply") }
            if rows.isEmpty { out("No public links."); return }
            for row in rows {
                out("\(row["id"] as? String ?? "?")  \(row["state"] as? String ?? "?")  \(row["containerName"] as? String ?? "?"):\(row["containerPort"] as? Int ?? 0)  \(row["url"] as? String ?? "")")
                if let detail = row["detail"] as? String { out("  \(detail)") }
            }
            return
        }
        if args.first == "stop" {
            guard args.count == 2, args[1] == "--all" || UUID(uuidString: args[1]) != nil else { throw CLIError.usage(linkUsage) }
            _ = try linkRequest("POST", "/noodle/links/stop", ["id": args[1]])
            out("Public link\(args[1] == "--all" ? "s" : "") stopped.")
            return
        }
        let flags = yesFlags.union(["--allow-privileged", "--json"])
        let positionals = args.filter { !flags.contains($0) }
        guard positionals.count == 1, args.count == Set(args).count else { throw CLIError.usage(linkUsage) }
        let raw = positionals[0]
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let name = parts.first, !name.isEmpty, !name.hasPrefix("-"),
              !raw.contains("/"), !raw.contains("\\") else { throw CLIError.usage("use CONTAINER[:PORT], never a socket path or URL") }
        var request: [String: Any] = ["container": String(name), "allowPrivileged": args.contains("--allow-privileged")]
        if parts.count == 2 {
            guard let port = Int(parts[1]), (1...65535).contains(port) else { throw CLIError.usage("container port must be between 1 and 65535") }
            request["port"] = port
        }
        let preview = try linkRequest("POST", "/noodle/links/target", request)
        guard let target = try JSONSerialization.jsonObject(with: preview) as? [String: Any],
              let id = target["containerID"] as? String, let name = target["containerName"] as? String,
              let ip = target["containerIP"] as? String, let port = target["containerPort"] as? Int else {
            throw CLIError("invalid container target reply")
        }
        err("This publishes every HTTP path on container \(name) (\(id.prefix(12))), \(ip):\(port), to the internet at a temporary HTTPS URL. Anyone with the URL can connect. Cloudflare can read request and response headers and bodies, including credentials. Noodle adds no authentication.")
        err("The published app keeps whatever it can reach: its mounted Mac folders, its networks and the other containers on them, host.docker.internal and so Mac services on this machine, and the internet. Its visitors reach it as requests from a private gateway address, so any check that trusts the source address will trust them.")
        for warning in target["warnings"] as? [String] ?? [] { err("Warning: \(warning).") }
        if !hasYes(args) {
            guard isatty(STDIN_FILENO) != 0 else { throw CLIError.usage("publishing needs confirmation; pass --yes to proceed without a terminal") }
            err("Publish this service? Type yes to continue:")
            guard readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "yes" else { throw CLIError("public link cancelled") }
        }
        // Bind consent to the resolved immutable ID and the exact previewed container port.
        request["container"] = id; request["port"] = port; request["confirmed"] = true
        let data = try linkRequest("POST", "/noodle/links", request)
        if args.contains("--json") { FileHandle.standardOutput.write(data + Data([10])); return }
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any], let url = row["url"] as? String else { throw CLIError("tunnel did not return a public URL") }
        out(url)
        out("Stop with noodle link stop \(row["id"] as? String ?? "--all"). Container stop or daemon exit also revokes this link.")
    } catch { die(error) }
}

/// One event-driven supervisor per link. No polling, account, inherited token, config or log file.
/// Closing the daemon's lifetime pipe, including on SIGKILL, reaps cloudflared. Helper exit is propagated.
private func linkSupervise(binary: String, target: String, directory: String, sha256: String) -> Never {
    guard binary.hasPrefix("/"), directory.hasPrefix("/"),
          let url = URLComponents(string: target), url.scheme == "http", url.host == "127.0.0.1",
          let port = url.port, (1...65535).contains(port), url.path.isEmpty, url.query == nil, url.user == nil else {
        die("invalid public link supervisor target")
    }
    guard Digest.isValid(sha256), (try? Digest.sha256(file: URL(fileURLWithPath: binary))) == sha256 else {
        die("cloudflared SHA-256 mismatch before execution")
    }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: binary)
    child.arguments = ["tunnel", "--no-autoupdate", "--config", "/dev/null", "--metrics", "127.0.0.1:0", "--url", target]
    child.currentDirectoryURL = URL(fileURLWithPath: directory)
    // A fresh HOME prevents implicit account config. No user token, proxy, or telemetry environment is inherited.
    var environment = ["PATH": "/usr/bin:/bin", "HOME": directory]
    for key in ["NOODLE_LINK_TEST_ARGS", "NOODLE_LINK_TEST_PID"] { environment[key] = env[key] }
    child.environment = environment
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.standardOutput; child.standardError = FileHandle.standardError
    child.terminationHandler = { process in exit(process.terminationStatus) }
    // These pipes carry no request data. EOF is a kernel-delivered lifetime notification.
    do { try child.run() } catch { die("cannot launch cloudflared: \(error.localizedDescription)") }
    // The daemon records this PID: if this supervisor dies alone, it kills the helper itself.
    print("noodle-link-helper-pid=\(child.processIdentifier)"); fflush(stdout)
    let once = NSLock()
    var tearingDown = false
    func teardown() {
        once.lock()
        if tearingDown { once.unlock(); return }
        tearingDown = true; once.unlock()
        child.terminationHandler = nil
        if child.isRunning {
            child.terminate()
            let pid = child.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if child.isRunning { kill(pid, SIGKILL) } }
        }
        child.waitUntilExit()
        exit(0)
    }
    // SIGTERM, SIGINT and SIGHUP reap the helper too; only SIGKILL cannot be handled, and the daemon covers that case.
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { teardown() }
        source.resume(); sources.append(source)
    }
    _ = FileHandle.standardInput.readDataToEndOfFile()
    teardown()
    withExtendedLifetime(sources) {}
    exit(0)
}
