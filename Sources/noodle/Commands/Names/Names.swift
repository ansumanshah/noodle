import Foundation
import NoodleCore

/// `noodle names`: the local names the daemon currently serves.
func cmdNames(_ args: [String]) {
    let args = args.first == "list" && args.count <= 2 && args.dropFirst().allSatisfy({ $0 == "--json" }) ? Array(args.dropFirst()) : args
    if let sub = args.first, ["ca", "trust", "untrust"].contains(sub) {
        guard args.count <= 2 else { usageDie("usage: noodle names \(sub) [localhost|noodle.local]") }
        cmdNamesCA(sub, domain: args.count == 2 ? args[1] : "localhost"); return
    }
    if args.first == "add" || args.first == "remove" { cmdNamesHost(args); return }
    guard args.isEmpty || args == ["--json"] else { usageDie("usage: noodle names [--json] | add NAME PORT | remove NAME | ca|trust|untrust [localhost|noodle.local]") }
    guard let r = httpGet("/noodle/names"), r.status == 200 else { engineDownDie() }
    if args == ["--json"] { FileHandle.standardOutput.write(r.body + Data([10])); return }
    guard let o = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else { die("unexpected reply from the Noodle engine") }
    let port = o["port"] as? Int ?? 80
    if o["enabled"] as? Bool == false { out("Local names are off (NOODLE_LOCAL_NAMES=0)."); return }
    if let e = o["error"] as? String { err("noodle: \(e)") }
    if let n = o["notice"] as? String { err("noodle: \(n)") }
    let httpsPort = o["httpsPort"] as? Int
    let names = o["names"] as? [[String: Any]] ?? []
    if names.isEmpty { out("No names yet. A running container with a web port gets one; `noodle names add NAME PORT` names a process on this Mac. Publish or EXPOSE one, or set the app.noodle.http.port label."); return }
    for n in names {
        let host = n["host"] as? String ?? ""
        if let hp = httpsPort { out("https://\(host)\(hp == 443 ? "" : ":\(hp)")") }
        let kind = n["kind"] as? String ?? "container"
        let owner = kind == "host" ? "host" : (n["containerID"] as? String).map { String($0.prefix(12)) } ?? ""
        out("http://\(host)\(port == 80 ? "" : ":\(port)")  ->  \(owner)  \(n["ip"] as? String ?? ""):\(n["port"] as? Int ?? 0)")
    }
}

/// `noodle names ca|trust|untrust`: the local HTTPS authority. `trust` asks macOS for your password; nothing runs it silently.
func cmdNamesCA(_ sub: String, domain: String = "localhost") {
    guard let scope = LocalCA.Domain(rawValue: domain) else { usageDie("CA domain must be localhost or noodle.local") }
    let ca = LocalCA(paths: NoodlePaths.resolve(), domain: scope)
    do { try ca.ensureCA() } catch { die(error) }
    switch sub {
    case "ca": out(ca.certificate.path)
    case "trust":
        out("Adding \(ca.certificate.path) to your login keychain as a trusted root for SSL. macOS will ask for your password.")
        runTool(LocalCA.trustCommand(certificate: ca.certificate, keychain: LocalCA.loginKeychain))
    default: runTool(LocalCA.untrustCommand(certificate: ca.certificate))
    }
}

private func runTool(_ argv: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0]); p.arguments = Array(argv.dropFirst())
    do { try p.run() } catch { die(error) }
    p.waitUntilExit()
    if p.terminationStatus != 0 { exit(ExitCode.failure) }
}

/// `noodle names add NAME PORT | remove NAME`: a name for a process already listening on this Mac. No root, no hosts file.
private func cmdNamesHost(_ args: [String]) {
    let usage = "usage: noodle names add NAME PORT | remove NAME"
    do {
        if args[0] == "add" {
            guard args.count == 3, !args[1].hasPrefix("-"), let port = Int(args[2]), (1...65535).contains(port) else { usageDie(usage) }
            let body = try JSONSerialization.data(withJSONObject: ["name": args[1], "port": port])
            let reply = try DevCommand.request("POST", "/noodle/names/host", body: body)
            for t in (try JSONSerialization.jsonObject(with: reply) as? [[String: Any]]) ?? [] { out("\(t["host"] as? String ?? "") -> 127.0.0.1:\(port)") }
        } else {
            guard args.count == 2, !args[1].hasPrefix("-") else { usageDie(usage) }
            let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
            _ = try DevCommand.request("DELETE", "/noodle/names/host/" + (args[1].addingPercentEncoding(withAllowedCharacters: allowed) ?? args[1]))
            out("removed \(args[1])")
        }
    } catch { die(error) }
}
