import Foundation
import CryptoKit
import Testing
@testable import NoodleCore

@Suite struct UpdateTransportTests {
    @Test(arguments: [
        "https://updates.invalid/feed", "http://localhost:8000/feed",
        "http://127.0.0.1:8000/feed", "http://[::1]:8000/feed",
    ])
    func permitsSafeRedirects(destination: String) async throws {
        let request = try await redirect(to: destination)
        #expect(request?.url?.absoluteString == destination)
    }

    @Test(arguments: [
        "http://updates.invalid/feed", "http://localhost.evil.invalid/feed",
        "http://127.0.0.1.evil.invalid/feed", "ftp://localhost/feed", "file:///tmp/feed",
    ])
    func refusesUnsafeRedirects(destination: String) async throws {
        #expect(try await redirect(to: destination) == nil)
    }

    @Test func rejectsHostlessHTTP() throws {
        #expect(!UpdateClient.isAllowedTransport(try #require(URL(string: "http:/feed"))))
    }

    private func redirect(to destination: String) async throws -> URLRequest? {
        let original = try #require(URL(string: "https://updates.invalid/feed"))
        let target = try #require(URL(string: destination))
        let response = try #require(HTTPURLResponse(url: original, statusCode: 302,
                                                   httpVersion: "HTTP/1.1", headerFields: ["Location": destination]))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // Never resumed: exercise the actual delegate without network access.
        let task = session.dataTask(with: original)
        return await withCheckedContinuation { continuation in
            UpdateRedirectDelegate().urlSession(session, task: task,
                willPerformHTTPRedirection: response, newRequest: URLRequest(url: target)) {
                    continuation.resume(returning: $0)
                }
        }
    }
}

private struct Sandbox {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-update-\(UUID().uuidString.prefix(8))")
    var paths: NoodlePaths { NoodlePaths(root: base.appendingPathComponent("home")) }
    init() { try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true) }
    func cleanup() { try? FileManager.default.removeItem(at: base) }

    /// A signed-ad-hoc minimal app: a copy of /usr/bin/true plus an Info.plist.
    func makeApp(at dir: URL, version: String, build: Int, id: String = "dev.getnoodle.Noodle") throws -> URL {
        let app = dir.appendingPathComponent("Noodle.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macos.appendingPathComponent("Noodle"))
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "Noodle", "CFBundlePackageType": "APPL",
                                    "CFBundleShortVersionString": version, "CFBundleVersion": String(build)]
        try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", app.path])
        return app
    }

    func zip(_ app: URL, to name: String) throws -> URL {
        let out = base.appendingPathComponent(name)
        try UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, out.path])
        return out
    }
}

private let key = Curve25519.Signing.PrivateKey()
private var pub: String { key.publicKey.rawRepresentation.base64EncodedString() }

private func signed(_ f: UpdateFeed) -> UpdateFeed {
    var f = f
    // swiftlint:disable:next force_try
    f.signature = try! key.signature(for: f.signedMessage).base64EncodedString()
    return f
}
private func feed(build: Int = 2, arch: String = UpdateFeed.currentArch, sha: String = String(repeating: "a", count: 64), length: Int = 10) -> UpdateFeed {
    signed(UpdateFeed(version: "0.\(build).0", build: build, arch: arch, url: "Noodle.zip", length: length, sha256: sha))
}

@Suite struct UpdateFeedTests {
    @Test func acceptsSignedNewerFeed() throws {
        try UpdateVerifier.accept(feed(), publicKeyBase64: pub, currentBuild: 1)
    }

    @Test func rejectsTamperedMetadataAndWrongKey() throws {
        var f = feed()
        f.sha256 = String(repeating: "b", count: 64)
        #expect(throws: UpdateError.badSignature) { try UpdateVerifier.accept(f, publicKeyBase64: pub, currentBuild: 1) }
        f = feed(); f.build = 99
        #expect(throws: UpdateError.badSignature) { try UpdateVerifier.accept(f, publicKeyBase64: pub, currentBuild: 1) }
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(throws: UpdateError.badSignature) { try UpdateVerifier.accept(feed(), publicKeyBase64: other, currentBuild: 1) }
    }

    @Test func architectureIsBoundToTheSignature() throws {
        let other = UpdateFeed.currentArch == "arm64" ? "x86_64" : "arm64"
        #expect(throws: UpdateError.wrongArch(other)) { try UpdateVerifier.accept(feed(arch: other), publicKeyBase64: pub, currentBuild: 1) }
        var swapped = feed(arch: other); swapped.arch = UpdateFeed.currentArch
        #expect(throws: UpdateError.badSignature) { try UpdateVerifier.accept(swapped, publicKeyBase64: pub, currentBuild: 1) }
    }

    @Test func refusesDowngradesAndOldSystems() throws {
        #expect(throws: UpdateError.notNewer) { try UpdateVerifier.accept(feed(build: 2), publicKeyBase64: pub, currentBuild: 2) }
        var f = UpdateFeed(version: "9", build: 9, arch: UpdateFeed.currentArch, minimumSystem: "99.0", url: "x", length: 1, sha256: String(repeating: "a", count: 64))
        f = signed(f)
        #expect(throws: UpdateError.systemTooOld("99.0")) { try UpdateVerifier.accept(f, publicKeyBase64: pub, currentBuild: 1) }
    }

    @Test func feedURLsAreArchitectureSpecific() {
        #expect(UpdateFeed.feedURL(base: "https://updates.invalid/noodle", arch: "arm64")?.absoluteString == "https://updates.invalid/noodle/arm64/appcast.json")
        #expect(UpdateFeed.feedURL(base: "https://updates.invalid/noodle/", arch: "x86_64")?.absoluteString == "https://updates.invalid/noodle/x86_64/appcast.json")
        #expect(UpdateFeed.feedURL(base: "not a url", arch: "arm64") == nil)
    }

    @Test func transportMustBeHTTPSExceptLocalTesting() {
        #expect(UpdateClient.isAllowedTransport(URL(string: "https://updates.invalid/x")!))
        #expect(!UpdateClient.isAllowedTransport(URL(string: "http://example.com/x")!))
        #expect(UpdateClient.isAllowedTransport(URL(string: "http://127.0.0.1:8000/x")!))
        #expect(UpdateClient.isAllowedTransport(URL(fileURLWithPath: "/tmp/x")))
        #expect(!UpdateClient.isAllowedTransport(URL(string: "ftp://127.0.0.1/x")!))
    }

    @Test func rejectsRemoteHTTPFeedAndArtifactBeforeFetching() async throws {
        let config = UpdateConfig(feedBase: "http://updates.example/noodle", publicKey: pub, currentBuild: 1, currentVersion: "1")
        await #expect(throws: UpdateError.notConfigured) { _ = try await UpdateClient.check(config) }
        let sb = Sandbox(); defer { sb.cleanup() }
        var remote = feed()
        remote.url = "http://updates.example/Noodle.zip"
        await #expect(throws: UpdateError.self) {
            _ = try await UpdateClient.download(remote, feedURL: URL(string: "https://updates.example/appcast.json")!, into: sb.base)
        }
        for address in ["http://localhost.evil.example/x", "http://127.0.0.1.evil.example/x", "http://localhost@evil.example/x", "http://192.168.1.1/x"] {
            #expect(!UpdateClient.isAllowedTransport(URL(string: address)!))
        }
    }

    @Test func settingsCheckDailyOnlyWhenAutomatic() {
        var s = UpdateSettings()
        #expect(s.shouldCheck())
        s.lastCheck = Date()
        #expect(!s.shouldCheck())
        #expect(s.shouldCheck(now: Date().addingTimeInterval(90_000)))
        s.automatic = false
        #expect(!s.shouldCheck(now: Date().addingTimeInterval(990_000)))
    }
}

@Suite struct UpdateInstallTests {
    @Test func oversizedArtifactAndFeedAreRefusedWhileReceiving() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let dir = sb.base.appendingPathComponent(UpdateFeed.currentArch)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 200_000).write(to: dir.appendingPathComponent("Noodle.zip"))
        let f = feed(sha: String(repeating: "a", count: 64), length: 10)
        let dl = sb.base.appendingPathComponent("dl")
        await #expect(throws: UpdateError.self) {
            _ = try await UpdateClient.download(f, feedURL: dir.appendingPathComponent("appcast.json"), into: dl)
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dl.path)) ?? []).isEmpty)
        try Data(count: UpdateVerifier.maxFeedBytes + 1).write(to: dir.appendingPathComponent("appcast.json"))
        let config = UpdateConfig(feedBase: sb.base.absoluteString, publicKey: pub, currentBuild: 1, currentVersion: "1")
        await #expect(throws: UpdateError.self) { _ = try await UpdateClient.check(config) }
    }

    @Test func downloadRejectsTamperedArtifact() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        try FileManager.default.createDirectory(at: sb.base.appendingPathComponent("arm64"), withIntermediateDirectories: true)
        let artifact = sb.base.appendingPathComponent("arm64/Noodle.zip")
        try Data("genuine artifact".utf8).write(to: artifact)
        let good = feed(sha: Digest.sha256Hex(Data("genuine artifact".utf8)), length: 16)
        let url = sb.base.appendingPathComponent("arm64/appcast.json")
        let out = try await UpdateClient.download(good, feedURL: url, into: sb.base.appendingPathComponent("dl"))
        #expect(FileManager.default.fileExists(atPath: out.path))
        try Data("Genuine artifact".utf8).write(to: artifact)   // same length, one byte differs
        await #expect(throws: UpdateError.self) { _ = try await UpdateClient.download(good, feedURL: url, into: sb.base.appendingPathComponent("dl")) }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func stageValidatesAndInstallSwapsWithRollback() throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let apps = sb.base.appendingPathComponent("Applications")
        let current = try sb.makeApp(at: apps, version: "0.1.0", build: 1)
        let newApp = try sb.makeApp(at: sb.base.appendingPathComponent("build"), version: "0.2.0", build: 2)
        let zip = try sb.zip(newApp, to: "Noodle.zip")
        let f = feed(build: 2, length: 1)
        var f2 = f; f2.version = "0.2.0"; f2 = signed(f2)
        let state = try UpdateInstaller.stage(zip: zip, feed: f2, current: current, paths: sb.paths)
        #expect(state.phase == .staged)
        try UpdateInstaller.install(target: current, paths: sb.paths)
        let version = { (NSDictionary(contentsOf: current.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String }
        #expect(version() == "0.2.0")
        #expect(UpdateStore.load(sb.paths)?.phase == .installed)
        // Crash loop: two unconfirmed launches, the third rolls back.
        #expect(!UpdateInstaller.launchCheck(paths: sb.paths))
        #expect(!UpdateInstaller.launchCheck(paths: sb.paths))
        #expect(UpdateInstaller.launchCheck(paths: sb.paths))
        #expect(version() == "0.1.0")
        #expect(UpdateStore.load(sb.paths) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: apps.path) == ["Noodle.app"])
    }

    @Test func confirmDropsPreviousApp() throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let current = try sb.makeApp(at: sb.base.appendingPathComponent("Applications"), version: "0.1.0", build: 1)
        let newApp = try sb.makeApp(at: sb.base.appendingPathComponent("build"), version: "0.2.0", build: 2)
        var f = feed(build: 2, length: 1); f.version = "0.2.0"; f = signed(f)
        _ = try UpdateInstaller.stage(zip: try sb.zip(newApp, to: "n.zip"), feed: f, current: current, paths: sb.paths)
        try UpdateInstaller.install(target: current, paths: sb.paths)
        UpdateInstaller.confirm(paths: sb.paths)
        #expect(UpdateStore.load(sb.paths) == nil)
        #expect(!FileManager.default.fileExists(atPath: UpdateStore.previous(sb.paths).path))
    }

    @Test func stageRejectsWrongIdentityVersionAndBrokenSeal() throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let current = try sb.makeApp(at: sb.base.appendingPathComponent("Applications"), version: "0.1.0", build: 1)
        var f = feed(build: 2, length: 1); f.version = "0.2.0"; f = signed(f)
        let impostor = try sb.makeApp(at: sb.base.appendingPathComponent("a"), version: "0.2.0", build: 2, id: "com.example.other")
        #expect(throws: UpdateError.self) { _ = try UpdateInstaller.stage(zip: try sb.zip(impostor, to: "a.zip"), feed: f, current: current, paths: sb.paths) }
        let wrongVersion = try sb.makeApp(at: sb.base.appendingPathComponent("b"), version: "0.9.0", build: 2)
        #expect(throws: UpdateError.self) { _ = try UpdateInstaller.stage(zip: try sb.zip(wrongVersion, to: "b.zip"), feed: f, current: current, paths: sb.paths) }
        let broken = try sb.makeApp(at: sb.base.appendingPathComponent("c"), version: "0.2.0", build: 2)
        try Data("x".utf8).write(to: broken.appendingPathComponent("Contents/MacOS/extra"))   // breaks the seal
        #expect(throws: UpdateError.self) { _ = try UpdateInstaller.stage(zip: try sb.zip(broken, to: "c.zip"), feed: f, current: current, paths: sb.paths) }
        #expect(UpdateStore.load(sb.paths) == nil)
    }
}

@Suite struct UpdateInstallSafetyTests {
    private func stage(_ sb: Sandbox, target: URL, build: Int) throws {
        let app = try sb.makeApp(at: sb.base.appendingPathComponent("build\(build)"), version: "0.\(build).0", build: build)
        var f = feed(build: build, length: 1); f.version = "0.\(build).0"; f = signed(f)
        _ = try UpdateInstaller.stage(zip: try sb.zip(app, to: "n\(build).zip"), feed: f, current: target, paths: sb.paths)
    }

    @Test func refusesToReplaceANewerBuild() throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let apps = sb.base.appendingPathComponent("Applications")
        let target = try sb.makeApp(at: apps, version: "0.1.0", build: 1)
        try stage(sb, target: target, build: 2)
        // The target moves on to build 3 after staging.
        try FileManager.default.removeItem(at: target)
        _ = try sb.makeApp(at: apps, version: "0.3.0", build: 3)
        #expect(throws: UpdateError.notNewer) { try UpdateInstaller.install(target: target, paths: sb.paths) }
        #expect(UpdateInstaller.build(of: target) == 3)
        #expect(UpdateStore.load(sb.paths)?.phase == .staged)
        #expect(try FileManager.default.contentsOfDirectory(atPath: apps.path) == ["Noodle.app"])
    }

    @Test func failedCommitLeavesTheCurrentAppInPlace() throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let apps = sb.base.appendingPathComponent("Applications")
        let target = try sb.makeApp(at: apps, version: "0.1.0", build: 1)
        try stage(sb, target: target, build: 2)
        let dir = UpdateStore.dir(sb.paths).path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir) }
        #expect(throws: UpdateError.self) { try UpdateInstaller.install(target: target, paths: sb.paths) }
        #expect(UpdateInstaller.build(of: target) == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: apps.path) == ["Noodle.app"])
    }

    @Test func installedStateNamesThePreviousApp() throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let target = try sb.makeApp(at: sb.base.appendingPathComponent("Applications"), version: "0.1.0", build: 1)
        try stage(sb, target: target, build: 2)
        let state = try UpdateInstaller.install(target: target, paths: sb.paths)
        #expect(UpdateInstaller.build(of: target) == 2)
        #expect(UpdateInstaller.build(of: URL(fileURLWithPath: try #require(state.previous))) == 1)
        #expect(UpdateStore.load(sb.paths) == state)
    }
}
