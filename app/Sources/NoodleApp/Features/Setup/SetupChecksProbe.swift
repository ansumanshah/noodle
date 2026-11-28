import Foundation
import NoodleCore

extension SetupChecks {
    static func contextSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-setup-context-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        for name in ["desktop-linux", "orbstack"] {
            let dir = root.appendingPathComponent("contexts/meta/" + name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let socket = root.appendingPathComponent(name + ".sock")
            try Data().write(to: socket)
            let meta: [String: Any] = ["Name": name, "Endpoints": ["docker": ["Host": "unix://" + socket.path]]]
            try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        }
        try Data(#"{"currentContext":"desktop-linux"}"#.utf8).write(to: root.appendingPathComponent("config.json"))
        var environment = ["DOCKER_CONFIG": root.path, "DOCKER_HOST": "unix://" + root.appendingPathComponent("orbstack.sock").path]
        let selected = SetupProbe.contexts(environment: environment)
        try expect(selected.current == "orbstack", "DOCKER_HOST must beat the saved desktop-linux selection")
        environment["DOCKER_CONTEXT"] = "desktop-linux"
        try expect(SetupProbe.contexts(environment: environment).current == "desktop-linux", "DOCKER_CONTEXT must beat DOCKER_HOST")
        let noodleSocket = root.appendingPathComponent("noodle.sock").path
        try expect(SetupProbe.dockerTarget(noodleSocket: noodleSocket, environment: environment) == "desktop-linux",
                   "The status card must show the effective context")
        environment["DOCKER_CONTEXT"] = nil
        environment["DOCKER_HOST"] = "unix://" + noodleSocket
        try expect(SetupProbe.dockerTarget(noodleSocket: noodleSocket, environment: environment) == "Noodle",
                   "A host override selecting Noodle must beat the saved context")
        environment["DOCKER_CONTEXT"] = "default"
        try expect(SetupProbe.dockerTarget(noodleSocket: noodleSocket, environment: environment) == "Noodle",
                   "Docker's default context still uses DOCKER_HOST")
        environment["DOCKER_CONTEXT"] = nil
        environment["DOCKER_HOST"] = "ssh://user@example.test"
        try expect(SetupProbe.dockerTarget(noodleSocket: noodleSocket, environment: environment) == "Custom host",
                   "Do not show endpoint credentials in the sidebar")
    }

    /// Exercise a real login shell with a preserved bad command ahead of a working Docker command.
    /// This runs only tiny local scripts, with no app window, Docker engine or VM.
    static func terminalResolution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-setup-path-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("working"), withIntermediateDirectories: true)
        let bad = root.appendingPathComponent(".local/bin/docker")
        let good = root.appendingPathComponent("working/docker")
        try "#!/bin/sh\nexit 1\n".write(to: bad, atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho 'Docker version 29.9.3, build fixture'\n".write(to: good, atomically: true, encoding: .utf8)
        for file in [bad, good] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        try #"export PATH="$HOME/.local/bin:$HOME/working:/usr/bin:/bin""#
            .write(to: root.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        let blocked = await SetupProbe.terminalFacts(home: root.path, shell: "/bin/bash")
        try expect(!blocked.applied && blocked.conflict == bad.path, "A preserved bad command must block PATH verification: \(blocked)")
        try fm.removeItem(at: bad)
        try fm.createSymbolicLink(at: bad, withDestinationURL: good)
        let working = await SetupProbe.terminalFacts(home: root.path, shell: "/bin/bash")
        try expect(working.applied && working.conflict == nil, "The command a new terminal resolves must actually run")
        // A later startup assignment can put another directory first. Check what wins, not just ~/.local/bin.
        try "export PATH=\"$HOME/working:$HOME/.local/bin:/usr/bin:/bin\"\n"
            .write(to: root.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 1\n".write(to: good, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: good.path)
        let shadowed = await SetupProbe.terminalFacts(home: root.path, shell: "/bin/bash")
        try expect(!shadowed.applied && shadowed.conflict == good.path, "The actual first command must be checked")
    }

    static func skipDuringApply() async throws {
        let (flow, backend) = flow { found($0); $0.hold = ["install"] }
        await flow.detectAll()
        flow.startInstall()
        try await until("applying choices") { flow.applyingChoices }
        flow.abandon()
        try expect(flow.abandoned && flow.applyingChoices, "An active setup mutation must finish safely after skipping")
        backend.hold = []
        try await until("apply finished") { !flow.applyingChoices }
        try expect(!backend.calls.contains("start") && !backend.calls.contains("pull"), "A closed assistant must not start more work")
        let (detecting, readOnly) = self.flow { $0.hold = ["detect"] }
        detecting.begin()
        try await until("detecting") { readOnly.calls.contains("detect") }
        detecting.stopWork()
        try await until("detection stopped") { !detecting.stopping }
        try expect(!readOnly.calls.contains("sizes") && detecting.detection == nil, "Cancelled detection must not start network requests")
    }
}
