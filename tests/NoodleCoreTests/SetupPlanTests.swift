import Foundation
import Testing
@testable import NoodleCore

@Suite struct SetupPlanTests {
    private func detection(docker: Bool = true, compose: Bool = true, buildx: Bool = true,
                           engines: [SetupEngine] = []) -> SetupDetection {
        SetupDetection(tools: [
            SetupTool(name: "docker", path: docker ? "/usr/local/bin/docker" : nil),
            SetupTool(name: "docker-compose", path: compose ? "/p/compose" : nil),
            SetupTool(name: "docker-buildx", path: buildx ? "/p/buildx" : nil),
        ], engines: engines)
    }

    @Test func downloadsOnlyWhatIsMissing() {
        let plan = SetupPlan.make(detection(compose: false), sizes: ["docker-compose": 30, "docker": 99])
        #expect(plan.missing == ["docker-compose"])
        #expect(plan.downloadBytes == 30)
        #expect(SetupPlan.make(detection(), sizes: [:]).needsDownload == false)
    }

    @Test func unknownSizeIsNotGuessed() {
        let plan = SetupPlan.make(detection(docker: false, compose: false), sizes: ["docker": 20])
        #expect(plan.downloadBytes == nil)
        #expect(plan.size(of: "docker") == 20)
    }

    @Test func flagsUseOnlyExistingOnes() {
        #expect(SetupPlan.flags(download: true, addPath: true, useDefault: true) == ["setup", "--tools", "--path", "--use"])
        #expect(SetupPlan.flags(download: false, addPath: false, useDefault: false) == ["setup", "--no-use"])
    }

    @Test func defaultEngineRule() {
        #expect(SetupPlan.defaultEngine([]).on)
        let idle = SetupEngine(name: "orbstack", socket: "/s", reachable: false, inUse: false)
        #expect(SetupPlan.defaultEngine([idle]).on)
        let busy = SetupEngine(name: "desktop-linux", socket: "/s", reachable: true, inUse: true)
        let off = SetupPlan.defaultEngine([idle, busy])
        #expect(!off.on)
        #expect(off.reason == "Docker Desktop is your current engine. It stays untouched.")
    }

    @Test func versionsAreReadFromToolOutput() {
        #expect(SetupTool.parseVersion("Docker version 29.9.3, build abc") == "29.9.3")
        #expect(SetupTool.parseVersion("Docker Compose version v5.7.1") == "5.7.1")
        #expect(SetupTool.parseVersion("github.com/docker/buildx v0.39.0 0190e4b") == "0.39.0")
        #expect(SetupTool.parseVersion("no digits here") == nil)
        #expect(SetupTool(name: "docker", path: "/d", version: "29.9.3").label == "Docker CLI 29.9.3")
        #expect(SetupTool(name: "docker-buildx", path: nil).label == "Buildx")
    }

    @Test func onlyRunningEnginesWithItemsCanBeImported() {
        let items = ImportInventory(images: 12, volumes: 3)
        let full = SetupEngine(name: "desktop-linux", socket: "/s", reachable: true, inUse: true, inventory: items)
        let empty = SetupEngine(name: "colima", socket: "/s", reachable: true, inUse: false, inventory: ImportInventory())
        let stopped = SetupEngine(name: "orbstack", socket: "/s", reachable: false, inUse: false, inventory: items)
        let found = SetupDetection(tools: [], engines: [stopped, empty, full])
        #expect(found.importable == [full])
        #expect(found.importSource == full)
        #expect(SetupDetection(tools: [], engines: [stopped, empty]).importSource == nil)
    }

    @Test func pathRules() {
        #expect(SetupPlan.profileName(shell: "/bin/zsh") == ".zprofile")
        #expect(SetupPlan.profileName(shell: "/opt/homebrew/bin/bash") == ".bash_profile")
        #expect(SetupPlan.profileName(shell: "/opt/homebrew/bin/fish") == nil)
        #expect(SetupPlan.pathNeeded(profileTexts: ["", "alias a=b"]))
        #expect(!SetupPlan.startupFiles(shell: "/bin/zsh").contains(".bashrc"))
        #expect(!SetupPlan.startupFiles(shell: "/bin/bash").contains(".zshrc"))
        #expect(!SetupPlan.pathNeeded(profileTexts: ["export PATH=$HOME/.local/bin:$PATH"]))
        // Setup's own block carries a real PATH line, so it proves PATH. The marker comment alone proves nothing.
        let block = "\n# >>> Noodle PATH >>>\nexport PATH=\"$HOME/.local/bin:$PATH\"\n# <<< Noodle PATH <<<\n"
        #expect(!SetupPlan.pathNeeded(profileTexts: [block]))
        #expect(SetupPlan.pathNeeded(profileTexts: ["# >>> Noodle PATH >>>"]))
    }

    @Test func classifiesFailures() {
        #expect(SetupProblem.classify(code: 1, output: "noodle: download failed for docker: curl: (6) Could not resolve host: download.docker.com") == .noNetwork)
        #expect(SetupProblem.classify(code: 1, output: "noodle: cannot install docker: No space left on device") == .diskFull)
        #expect(SetupProblem.classify(code: 1, output: "noodle: SHA-256 mismatch for x; discarded.") == .brokenDownload)
        #expect(SetupProblem.classify(code: 1, output: "noodle: Docker CLI unavailable. Run `noodle setup --tools`") == .dockerMissing)
        #expect(SetupProblem.classify(code: 1, output: "noodle: --path supports zsh and bash; add") == .unsupportedShell)
        #expect(SetupProblem.classify(code: 1, output: "noodle: context noodle belongs to another installation; preserved") == .contextConflict)
        #expect(SetupProblem.classify(code: 127, output: "The noodle command line tool was not found.") == .cliMissing)
        #expect(SetupProblem.classify(code: 124, output: "Command timed out.") == .timedOut)
        #expect(SetupProblem.classify(code: 1, output: "x\nnoodle: something odd\n") == .unknown("something odd"))
    }

    @Test func exitZeroIsNotTrusted() {
        let ok = SetupFacts(dockerPath: "/d", daemonUp: true, dockerReachesNoodle: true)
        #expect(SetupVerdict.evaluate(code: 0, output: "Setup complete.", facts: ok) == nil)
        var f = ok; f.dockerPath = nil
        #expect(SetupVerdict.evaluate(code: 0, output: "Setup complete.", facts: f) == .dockerMissing)
        f = ok; f.daemonUp = false
        #expect(SetupVerdict.evaluate(code: 0, output: "", facts: f) == .daemonDown)
        f = ok; f.dockerReachesNoodle = false
        #expect(SetupVerdict.evaluate(code: 0, output: "", facts: f) == .brokenTool("The Docker command"))
        f = ok; f.pathApplied = false
        #expect(SetupVerdict.evaluate(code: 0, output: "", facts: f) == .pathNotApplied)
        #expect(SetupVerdict.evaluate(code: 1, output: "curl: (6)", facts: ok) == .noNetwork)
    }

    @Test func missingPluginsAreNotFatalButAreReported() {
        let out = "docker: using /d\nMissing client tools: docker-compose, docker-buildx. To download the pinned clients, run `noodle setup --tools`.\nSetup complete."
        #expect(SetupVerdict.missingTools(out) == ["docker-compose", "docker-buildx"])
        #expect(SetupVerdict.missingTools("Setup complete.").isEmpty)
    }

    @Test func containerVerdict() {
        #expect(SetupVerdict.container(code: 0, output: "Hello from Noodle\n", greeting: "Hello from Noodle") == nil)
        #expect(SetupVerdict.container(code: 0, output: "", greeting: "Hello from Noodle") != nil)
        #expect(SetupVerdict.container(code: 0, output: "Pulled alpine", greeting: "") == nil)
        #expect(SetupVerdict.container(code: 0, output: "", greeting: "") == nil)
        #expect(SetupVerdict.container(code: 1, output: "dial tcp: lookup registry-1.docker.io: no such host", greeting: "x") == .noNetwork)
        #expect(SetupVerdict.container(code: 125, output: "boom", greeting: "x") == .containerFailed("boom"))
    }

    @Test func downloadFractionNeverFinishesEarly() {
        let expected: [String: Int64] = ["a.tgz": 100, "b": 100]
        #expect(SetupProgress.downloadFraction(files: [:], expected: expected) == 0)
        #expect(SetupProgress.downloadFraction(files: ["a.tgz": 100, "b": 50], expected: expected) == 0.75)
        #expect(SetupProgress.downloadFraction(files: ["a.tgz": 900, "b": 100, "docker": 500], expected: expected) == 0.99)
        #expect(SetupProgress.downloadFraction(files: ["a": 1], expected: [:]) == 0)
    }

    @Test func pullProgressCountsLayers() {
        var p = PullProgress()
        for line in ["Using default tag: latest", "latest: Pulling from library/alpine", "9824c27679d3: Pulling fs layer",
                     "abcdef123456: Pulling fs layer", "9824c27679d3: Pull complete"] { p.ingest(line) }
        #expect(p.fraction == 0.5)
        p.ingest("abcdef123456: Pull complete"); p.ingest("Digest: sha256:1"); p.ingest("Status: Downloaded newer image for alpine:latest")
        #expect(p.fraction == 1)
        var cached = PullProgress(); cached.ingest("Status: Image is up to date for alpine:latest")
        #expect(cached.fraction == 1)
    }

    @Test func importInventoryParsesTheListing() {
        let text = """
        images (3 tagged, 2 untagged, untagged are never copied)
          alpine:latest  7.0 MiB
        volumes (1)
        stopped containers (2 of 5 total; running ones are not copied)
        """
        let inv = ImportInventory.parse(text)
        #expect(inv == ImportInventory(images: 3, volumes: 1, containers: 2))
        #expect(inv.summary == "3 images, 1 volume and 2 stopped containers")
        #expect(ImportInventory.parse("").isEmpty)
        #expect(ImportInventory(images: 1).summary == "1 image")
    }

    @Test func durations() {
        #expect(SetupProgress.duration(milliseconds: 412) == "412 ms")
        #expect(SetupProgress.duration(milliseconds: 1340) == "1.3 s")
        #expect(SetupProgress.duration(milliseconds: 12_400) == "12 s")
    }
}
