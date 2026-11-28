import Foundation
import NoodleCore

extension ModelStore {
    /// Curl arguments that send the signed-in Hugging Face token, only to huggingface.co. The header goes through a
    /// private temporary file so the token never shows in the process list. Other hosts and signed-out users get none.
    static func isHuggingFace(_ url: String) -> Bool {
        let parts = URL(string: url)
        return parts?.scheme?.lowercased() == "https" && parts?.host?.lowercased() == "huggingface.co"
    }

    func withHuggingFaceAuth<T>(for url: String, _ body: ([String]) throws -> T) throws -> T {
        guard Self.isHuggingFace(url), let token = BrowserSignIn.huggingFaceToken() else { return try body([]) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hf-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        guard FileManager.default.createFile(atPath: file.path, contents: Data("Authorization: Bearer \(token)\n".utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CLIError("could not prepare the Hugging Face sign-in for this download. Check free space and try again.")
        }
        // https only, also across redirects, so the token cannot be sent in clear.
        return try body(["--proto", "=https", "--proto-redir", "=https", "-H", "@" + file.path])
    }
}
