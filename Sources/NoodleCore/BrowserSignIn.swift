import Foundation

/// "Sign in with browser" without an OAuth app: open the provider's own token page with the right options
/// pre-selected, then check the pasted token against the provider before anything is saved.
public enum BrowserSignIn {
    public enum Provider: String, CaseIterable, Sendable, Identifiable {
        case github, huggingFace, ecr
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .github: "GitHub Container Registry"
            case .huggingFace: "Hugging Face"
            case .ecr: "Amazon ECR"
            }
        }

        /// The registry host `docker login` stores the token for. Nil when the token is not a registry sign-in.
        public var registry: String? {
            switch self {
            case .github: "ghcr.io"
            case .huggingFace: nil
            case .ecr: nil
            }
        }

        /// The provider's own page for making a token, scopes already ticked. Nil for ECR, which has no such page.
        public var tokenPage: URL? {
            switch self {
            case .github: Self.githubTokenPage(git: false)
            case .huggingFace: URL(string: "https://huggingface.co/settings/tokens/new?tokenType=read")
            case .ecr: nil
            }
        }

        /// Plain words shown beside the button.
        public var explanation: String {
            switch self {
            case .github: "Opens GitHub with permission to read packages already ticked. Create the token, copy it, and paste it here."
            case .huggingFace: "Opens Hugging Face with a read-only token ready to create. Create it, copy it, and paste it here. Needed for models that ask you to accept terms first."
            case .ecr: "Amazon does not offer a token page. Run this once in Terminal, with the AWS command line installed and signed in:"
            }
        }

        /// GitHub's token page. `git` adds the `repo` scope so the same token can clone private repositories.
        public static func githubTokenPage(git: Bool) -> URL {
            URL(string: "https://github.com/settings/tokens/new?scopes=read:packages\(git ? ",repo" : "")&description=Noodle")!
        }

        /// What `git credential approve` reads on stdin to store a github.com sign-in in the user's own helper.
        /// Nil when a value holds a line break, which would let it add its own fields.
        public static func gitCredential(user: String, token: String) -> String? {
            guard !(user + token).contains(where: \.isNewline) else { return nil }
            return "protocol=https\nhost=github.com\nusername=\(user)\npassword=\(token)\n\n"
        }

        public static let ecrCommand = "aws ecr get-login-password --region <region> | docker login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com"
    }

    public struct Failure: Error, LocalizedError, Equatable {
        public let errorDescription: String?
        public init(_ m: String) { errorDescription = m }
    }

    /// Asks the provider who owns `token`. Returns the account name; throws a plain-words reason otherwise.
    public static func validate(_ token: String, for provider: Provider, session: URLSession = .shared) async throws -> String {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.count <= 512, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw Failure("That does not look like a token. Paste only the token itself.")
        }
        let url: String, field: String
        switch provider {
        case .github: (url, field) = ("https://api.github.com/user", "login")
        case .huggingFace: (url, field) = ("https://huggingface.co/api/whoami-v2", "name")
        case .ecr: throw Failure("Amazon ECR signs in from Terminal.")
        }
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("Noodle", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw Failure("Could not reach \(provider.title). Check your internet connection and try again.") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, data.count <= 1_048_576,
              let name = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?[field] as? String, !name.isEmpty else {
            throw Failure(status == 401 || status == 403 ? "\(provider.title) did not accept this token. Make a new one and try again."
                                                          : "\(provider.title) gave an unexpected answer (\(status)). Try again later.")
        }
        return name
    }

    // MARK: - Hugging Face token file

    /// The file the Hugging Face tools themselves read (`hf auth login`), so one sign-in serves them all.
    public static func huggingFaceTokenFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = environment["HF_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()) + "/.cache/huggingface"
        return URL(fileURLWithPath: home).appendingPathComponent("token")
    }

    /// `HF_TOKEN` wins, then the token file. Nil when signed out.
    public static func huggingFaceToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let t = environment["HF_TOKEN"], !t.isEmpty { return t.trimmingCharacters(in: .whitespacesAndNewlines) }
        let text = try? String(contentsOf: huggingFaceTokenFile(environment: environment), encoding: .utf8)
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return t?.isEmpty == false ? t : nil
    }

    public static func saveHuggingFaceToken(_ token: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let file = huggingFaceTokenFile(environment: environment)
        do { try PrivateFile.write(Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8), to: file, ownFolder: false) } catch {
            throw Failure("Could not save the token to \(file.path). Check that the folder is writable.")
        }
    }
}
