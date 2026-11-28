import Foundation
import Darwin

extension DevCommand {
    static func request(_ method: String, _ path: String, body: Data? = nil) throws -> Data {
        let reply: HTTPReply
        do {
            reply = try DockerHTTP(socketPath: socketPath, timeout: 5).request(
                method, path, headers: body == nil ? [:] : ["Content-Type": "application/json"], body: body.map { .data($0) } ?? .none)
        } catch {
            throw CLIError("Cannot reach the Noodle engine. Start it before running noodle dev.", exitCode: ExitCode.engineDown)
        }
        let payload = reply.body, code = reply.status
        guard (200..<300).contains(code) else {
            let message = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["message"] as? String
            throw CLIError(message ?? "Dev route request failed (HTTP \(code)).")
        }
        return payload
    }
}
