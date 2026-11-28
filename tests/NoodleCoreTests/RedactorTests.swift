import Foundation
import Testing
@testable import NoodleCore

@Suite struct RedactorTests {
    static let canaries = [
        "ghp_CANARY0123456789abcdefghijklmnop",
        "sk-ant-CANARYabcdefghijklmnopqrstuv",
        "AKIACANARY0123456789",
        "hunter2canary",
        "Zm9vOmNhbmFyeXBhc3N3b3Jk",
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJjYW5hcnkifQ.CANARYsig12",
        "s3cretEnvCanary",
        "registryCanaryPw",
        "xoxb-CANARY-1234567890",
        "npm_CANARYtoken0123456789abcd",
    ]
    static let home = "/Users/canaryuser"

    static let planted = """
    2026-11-05 pull ghcr.io/acme/app Authorization: Bearer ghp_CANARY0123456789abcdefghijklmnop
    request header authorization=Basic Zm9vOmNhbmFyeXBhc3N3b3Jk
    {"auths":{"ghcr.io":{"auth":"Zm9vOmNhbmFyeXBhc3N3b3Jk","password":"registryCanaryPw","identitytoken":"hunter2canary"}}}
    fetching https://deploy:hunter2canary@registry.example.com/v2/
    env: DATABASE_PASSWORD=hunter2canary API_TOKEN="s3cretEnvCanary" PATH=/usr/bin
    docker login --password registryCanaryPw -u bob
    docker login --password=registryCanaryPw
    key sk-ant-CANARYabcdefghijklmnopqrstuv aws AKIACANARY0123456789
    jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJjYW5hcnkifQ.CANARYsig12 slack xoxb-CANARY-1234567890 npm npm_CANARYtoken0123456789abcd
    mount /Users/canaryuser/Code/app/.env failed; also /Users/someoneelse/x
    -----BEGIN OPENSSH PRIVATE KEY-----
    s3cretEnvCanary
    -----END OPENSSH PRIVATE KEY-----
    """

    @Test func noCanarySurvives() {
        let out = Redactor(home: Self.home).redact(Self.planted)
        for c in Self.canaries { #expect(!out.contains(c), "leaked \(c)") }
        #expect(!out.contains("canaryuser"))
        #expect(!out.contains("someoneelse"))
    }

    @Test func keepsContextReadable() {
        let out = Redactor(home: Self.home).redact(Self.planted)
        #expect(out.contains("DATABASE_PASSWORD=[redacted]"))
        #expect(out.contains("PATH=/usr/bin"))
        #expect(out.contains("https://[redacted]@registry.example.com/v2/"))
        #expect(out.contains("mount ~/Code/app/.env failed"))
        #expect(out.contains("-u bob"))
        #expect(out.contains("pull ghcr.io/acme/app"))
    }

    @Test func plainLinesAreUntouched() {
        let line = "noodled: listening on /tmp/x/run/docker.sock; container 3f2a started, 12 layers"
        #expect(Redactor(home: nil).redact(line) == line)
    }
}

@Suite struct RedactorTableTests {
    static let cases: [(String, String)] = [
        ("curl https://u:tableSecret1@host/x", "tableSecret1"),
        ("Authorization: Digest username=\"a\", response=tableSecret2", "tableSecret2"),
        ("authorization: AWS4-HMAC-SHA256 Credential=tableSecret3/x", "tableSecret3"),
        ("-----BEGIN RSA PRIVATE KEY-----\ntableSecret4\n-----END RSA PRIVATE KEY-----", "tableSecret4"),
        ("run --password tableSecret5", "tableSecret5"),
        ("run --token=tableSecret6", "tableSecret6"),
        ("run --secret tableSecret7", "tableSecret7"),
        ("password: tableSecret8", "tableSecret8"),
        ("api key = tableSecret9 key = tableSecret9b", "tableSecret9b"),
        ("Cookie: sid=tableSecret10; a=b", "tableSecret10"),
        ("Set-Cookie: sid=tableSecret11; HttpOnly", "tableSecret11"),
        ("X-Api-Key: tableSecret12", "tableSecret12"),
        ("t eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0YWJsZSJ9.tableSig13", "tableSig13"),
        ("sk_live_tableSecret14abcdefgh", "tableSecret14"),
        ("rk_live_tableSecret15abcdefgh", "tableSecret15"),
        ("xoxp-tableSecret16-123456", "tableSecret16"),
        ("sk-ant-tableSecret17abcdefghijkl", "tableSecret17"),
        ("sk-tableSecret18abcdefghijklmnop", "tableSecret18"),
        ("ghp_tableSecret19abcdefghijklmn", "tableSecret19"),
        ("github_pat_tableSecret20abcdefghij", "tableSecret20"),
        ("hf_tableSecret21abcdefghijklmnop", "tableSecret21"),
        ("AKIATABLESECRET22000", "TABLESECRET22"),
        ("/Users/tableuser23/Code", "tableuser23"),
    ]

    @Test(arguments: cases) func redacts(_ input: String, _ secret: String) {
        let out = Redactor(home: "/Users/tableuser23").redact(input)
        #expect(!out.contains(secret), "leaked \(secret) in \(out)")
    }

    @Test(arguments: ["passed: 5", "bypass: true", "max_tokens: 256", "tokens_per_second: 41.2", "passing: yes", "compass: north"])
    func keepsNonSecretKeys(_ line: String) {
        #expect(Redactor(home: nil).redact(line) == line)
    }

    @Test(arguments: ["access_token: tableX", "db-password: tableX", "client.secret: tableX", "pass: tableX"])
    func redactsSecretKeySegments(_ line: String) {
        #expect(!Redactor(home: nil).redact(line).contains("tableX"))
    }

    @Test func hostileInputIsFast() {
        let r = Redactor(home: nil)
        let start = Date()
        _ = r.redact(String(repeating: "a:", count: 20_000) + String(repeating: " password", count: 5_000) + "-----BEGIN X-----" + String(repeating: "x", count: 50_000))
        #expect(Date().timeIntervalSince(start) < 5)
    }
}

@Suite struct DiagnosticLogsTests {
    private func makeHome() throws -> (NoodlePaths, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-diag-test-\(UUID().uuidString)")
        let root = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("privileged"), withIntermediateDirectories: true)
        return (NoodlePaths(root: root), base)
    }

    @Test func tailFiltersAndLimits() throws {
        let (paths, base) = try makeHome()
        defer { try? FileManager.default.removeItem(at: base) }
        let log = LogComponent.engine.file(in: paths)
        try (1...50).map { "line \($0) \($0 % 2 == 0 ? "even" : "odd")" }.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        #expect(DiagnosticLogs.tail(log, count: 3) == ["line 48 even", "line 49 odd", "line 50 even"])
        #expect(DiagnosticLogs.tail(log, count: 2, filter: "ODD") == ["line 47 odd", "line 49 odd"])
        #expect(DiagnosticLogs.tail(paths.vmLog, count: 5).isEmpty)
    }

    @Test func archiveIsScrubbed() throws {
        let (paths, base) = try makeHome()
        defer { try? FileManager.default.removeItem(at: base) }
        try RedactorTests.planted.write(to: LogComponent.engine.file(in: paths), atomically: true, encoding: .utf8)
        try RedactorTests.planted.write(to: paths.vmLog, atomically: true, encoding: .utf8)
        try RedactorTests.planted.write(to: paths.workloadVMLog, atomically: true, encoding: .utf8)
        try "{\"approved_directories\":[\"/Users/canaryuser/Code\"],\"token\":\"hunter2canary\"}".write(to: paths.settingsFile, atomically: true, encoding: .utf8)
        let archive = base.appendingPathComponent("out.tar.gz")
        try DiagnosticLogs.writeArchive(paths: paths, to: archive, redactor: Redactor(home: RedactorTests.home), version: "test")
        let extract = base.appendingPathComponent("x")
        try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-xzf", archive.path, "-C", extract.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let files = FileManager.default.enumerator(at: extract, includingPropertiesForKeys: [.isRegularFileKey])!.compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath }
        #expect(files.count == 5)   // info, settings, three logs
        #expect(Set(files.map(\.lastPathComponent)) == ["info.txt", "settings.json", "engine.log", "linux.log", "privileged.log"])
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for c in RedactorTests.canaries { #expect(!text.contains(c), "\(f.lastPathComponent) leaked \(c)") }
            #expect(!text.contains("canaryuser"))
        }
        let mode = try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
