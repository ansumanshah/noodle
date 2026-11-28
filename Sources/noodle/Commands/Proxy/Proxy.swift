import Foundation

/// Proxy URLs are accepted on stdin so credentials do not enter process arguments or shell history.
func cmdProxy(_ args: [String]) {
    if args == ["help"] || args == ["--help"] {
        out(CommandTable.groupHelp("proxy"))
        return
    }
    guard args.isEmpty || args == ["--json"] || args == ["set", "--stdin"] else {
        usageDie("usage: noodle proxy [--json] | set --stdin | help")
    }
    let setting = args == ["set", "--stdin"]
    do {
        let body: RequestBody
        if setting {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                usageDie("proxy settings must be a JSON object")
            }
            body = .data(data)
        } else { body = .none }
        let reply = try DockerHTTP(socketPath: socketPath).request(setting ? "POST" : "GET", "/noodle/proxy",
            headers: setting ? ["Content-Type": "application/json"] : [:], body: body)
        guard (200..<300).contains(reply.status) else {
            let loopbackError = "containers cannot reach a loopback-only proxy; listen on a non-loopback address or set proxy variables per container"
            if let object = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any],
               object["message"] as? String == loopbackError { die(loopbackError) }
            // Do not print a server error that might quote submitted settings.
            die("proxy settings request failed (HTTP \(reply.status)); credentialed URLs cannot be injected")
        }
        FileHandle.standardOutput.write(reply.body + Data([10]))
    } catch { engineDownDie("cannot reach the Noodle engine to read or change proxy settings") }
}
