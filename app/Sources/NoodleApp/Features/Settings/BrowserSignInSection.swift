import AppKit
import NoodleCore
import SwiftUI

/// One sign-in flow for registries and Hugging Face: open the provider's token page, paste the token, check it, save it.
struct BrowserSignInSection: View {
    let providers: [BrowserSignIn.Provider]
    let docker: String?
    let demo: Bool
    var onSaved: () -> Void = {}
    @State private var provider: BrowserSignIn.Provider
    @State private var token = ""
    @State private var busy = false
    @State private var notice: String?
    @State private var useForGit = false

    init(providers: [BrowserSignIn.Provider], docker: String?, demo: Bool, onSaved: @escaping () -> Void = {}) {
        self.providers = providers; self.docker = docker; self.demo = demo; self.onSaved = onSaved
        _provider = State(initialValue: providers[0])
    }

    var body: some View {
        Section {
            if providers.count > 1 {
                Picker("Service", selection: $provider) {
                    ForEach(providers) { Text($0.title).tag($0) }
                }
            }
            Text(provider.explanation).foregroundStyle(.secondary)
            if let page = provider.tokenPage {
                if provider == .github {
                    Toggle("Also use for git clone and runners", isOn: $useForGit).disabled(busy || demo)
                    .help("Turn this on before Sign in with browser, so the token page asks for repository access too, which GitHub Actions runners need.")
                }
                Button("Sign in with browser") {
                    NSWorkspace.shared.open(provider == .github ? BrowserSignIn.Provider.githubTokenPage(git: useForGit) : page)
                }.disabled(demo)
                SecureField("Paste the token here", text: $token).disabled(busy || demo)
                Button("Check and Save") { Task { await save() } }.disabled(busy || demo || token.isEmpty)
            } else {
                Text(BrowserSignIn.Provider.ecrCommand).textSelection(.enabled).font(.system(.caption, design: .monospaced))
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(BrowserSignIn.Provider.ecrCommand, forType: .string)
                }
            }
            if let notice { Text(notice).foregroundStyle(.secondary) }
        } header: {
            Text("Sign in")
        }
        .onChange(of: provider) { token = ""; notice = nil }
    }

    private func save() async {
        busy = true; defer { busy = false }
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let account = try await BrowserSignIn.validate(value, for: provider)
            switch provider {
            case .huggingFace: try BrowserSignIn.saveHuggingFaceToken(value)
            case .github:
                guard let docker else { throw BrowserSignIn.Failure("Docker command line tool not found.") }
                // The token goes to docker over stdin into Docker's own credential store, never into arguments.
                let code = await Task.detached { Self.feed(docker, ["login", "ghcr.io", "-u", account, "--password-stdin"], value) }.value
                guard code == 0 else { throw BrowserSignIn.Failure("Docker could not save the sign-in. Try docker login in Terminal.") }
                if useForGit {
                    let helper = await Task.detached { Self.gitHelperConfigured() }.value
                    guard helper else {
                        throw BrowserSignIn.Failure("Signed in for images. Git has no credential helper set, so the sign-in was not saved for git. Run git config --global credential.helper osxkeychain, then try again.")
                    }
                    guard let input = BrowserSignIn.Provider.gitCredential(user: account, token: value) else {
                        throw BrowserSignIn.Failure("Signed in for images, but this token cannot be saved for git.")
                    }
                    let git = await Task.detached { Self.feed("/usr/bin/git", ["credential", "approve"], input) }.value
                    guard git == 0 else { throw BrowserSignIn.Failure("Signed in for images, but git could not save the sign-in.") }
                }
            case .ecr: return
            }
            token = ""
            notice = "Signed in as \(account)."
            onSaved()
        } catch {
            notice = error.localizedDescription
        }
    }

    /// True when git is installed (Command Line Tools present) and a credential helper is set, so `approve` stores something.
    private nonisolated static func gitHelperConfigured() -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        probe.arguments = ["-p"]
        probe.standardOutput = FileHandle.nullDevice; probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return false }
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["config", "--get", "credential.helper"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 && !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Run a tool with the secret on stdin, so it never appears in arguments.
    private nonisolated static func feed(_ tool: String, _ arguments: [String], _ secret: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        let input = Pipe()
        p.standardInput = input; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return 126 }
        // The throwing write: the old one raises an Objective-C exception when the tool already closed stdin.
        try? input.fileHandleForWriting.write(contentsOf: Data(secret.utf8))
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus
    }
}
