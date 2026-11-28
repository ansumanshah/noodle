import Foundation
import Testing
@testable import NoodleCore

@Suite struct SetupEnvironmentTests {
    private let pathLine = "export PATH=\"$HOME/.local/bin:$PATH\""

    // MARK: terminal PATH

    @Test func bashReadsOnlyTheFirstLoginFile() {
        // .profile has the line, but .bash_profile exists and never loads it: a new login shell misses it.
        let files = [".bash_profile": "alias a=b", ".profile": pathLine]
        #expect(SetupPlan.pathNeeded(shell: "/bin/bash", files: files))
        // The same layout where .bash_profile loads .profile is fine.
        let loads = [".bash_profile": "if [ -f ~/.profile ]; then . ~/.profile; fi", ".profile": pathLine]
        #expect(!SetupPlan.pathNeeded(shell: "/bin/bash", files: loads))
        // .bash_login is ignored while .bash_profile exists.
        #expect(SetupPlan.pathNeeded(shell: "/bin/bash", files: [".bash_profile": "x", ".bash_login": pathLine]))
        // With no .bash_profile, .bash_login is the one bash reads.
        #expect(!SetupPlan.pathNeeded(shell: "/bin/bash", files: [".bash_login": pathLine]))
    }

    @Test func bashrcCountsOnlyWhenSourced() {
        let sourced = [".bash_profile": "[ -f ~/.bashrc ] && . ~/.bashrc", ".bashrc": pathLine]
        #expect(!SetupPlan.pathNeeded(shell: "/bin/bash", files: sourced))
        let throughProfile = [".bash_profile": ". ~/.profile", ".profile": "source ~/.bashrc", ".bashrc": pathLine]
        #expect(!SetupPlan.pathNeeded(shell: "/bin/bash", files: throughProfile))
        #expect(SetupPlan.pathNeeded(shell: "/bin/bash", files: [".bash_profile": "echo hi", ".bashrc": pathLine]))
        // Naming the file in an echo is not loading it.
        #expect(SetupPlan.pathNeeded(shell: "/bin/bash", files: [".bash_profile": "echo ~/.bashrc", ".bashrc": pathLine]))
    }

    @Test func aCommentedLineIsNotProof() {
        #expect(SetupPlan.pathNeeded(shell: "/bin/zsh", files: [".zprofile": "# " + pathLine]))
        #expect(SetupPlan.pathNeeded(shell: "/bin/zsh", files: [".zshrc": "  #" + pathLine + "\n"]))
        #expect(!SetupPlan.pathNeeded(shell: "/bin/zsh", files: [".zshrc": "# note\n" + pathLine]))
        #expect(!SetupPlan.pathNeeded(shell: "/bin/zsh", files: [".zshenv": "path+=(~/.local/bin)"]))
    }

    @Test func unprovenShellsNeedTheStep() {
        #expect(SetupPlan.pathNeeded(shell: "/opt/homebrew/bin/fish", files: [".profile": pathLine]))
        #expect(SetupPlan.pathNeeded(shell: "/bin/bash", files: [:]))
        #expect(SetupPlan.pathNeeded(shell: "/bin/zsh", files: [:]))
    }

    @Test func mentioningPathDoesNotConfigureIt() {
        for text in ["echo 'export PATH=$HOME/.local/bin:$PATH'", "export OTHER_PATH=$HOME/.local/bin",
                     "export PATH=/someone/else/.local/bin:$PATH", "export PATH='$HOME/.local/bin:$PATH'",
                     "export PATH=/usr/bin # ~/.local/bin", "if false; then\n" + pathLine + "\nfi",
                     "setup_path() {\n" + pathLine + "\n}", pathLine + "\nexport PATH=/usr/bin"] {
            #expect(SetupPlan.pathNeeded(shell: "/bin/zsh", files: [".zprofile": text]), "Profile: \(text)")
        }
    }

    @Test func aCommentCannotSourceAnIgnoredProfile() {
        let files = [".bash_profile": "echo ready # source ~/.profile", ".profile": pathLine]
        #expect(SetupPlan.pathNeeded(shell: "/bin/bash", files: files))
        #expect(SetupPlan.pathNeeded(shell: "/bin/zsh", files: [".zprofile": pathLine, ".zshrc": "export PATH=/usr/bin"]))
    }

    @Test func noodleBlockNeedsItsLine() {
        let block = "# >>> Noodle PATH >>>\n\(pathLine)\n# <<< Noodle PATH <<<\n"
        #expect(SetupPlan.hasPathBlock("alias x=y\n" + block))
        #expect(!SetupPlan.hasPathBlock("# >>> Noodle PATH >>>\n# <<< Noodle PATH <<<\n"))
        #expect(!SetupPlan.hasPathBlock("# >>> Noodle PATH >>>\n# \(pathLine)\n# <<< Noodle PATH <<<\n"))
        #expect(!SetupPlan.hasPathBlock(pathLine))
    }

    // MARK: Docker selection

    @Test func overridesAreFoundInTheEnvironmentAndStartupFiles() {
        #expect(SetupPlan.dockerOverride(environment: ["DOCKER_CONTEXT": "orbstack"], profileTexts: []) == "DOCKER_CONTEXT")
        #expect(SetupPlan.dockerOverride(environment: ["DOCKER_HOST": "unix:///x.sock"], profileTexts: []) == "DOCKER_HOST")
        #expect(SetupPlan.dockerOverride(environment: [:], profileTexts: ["export DOCKER_HOST=unix:///x.sock"]) == "DOCKER_HOST")
        #expect(SetupPlan.dockerOverride(environment: [:], profileTexts: ["DOCKER_CONTEXT=colima"]) == "DOCKER_CONTEXT")
        #expect(SetupPlan.dockerOverride(environment: ["DOCKER_HOST": ""], profileTexts: ["# export DOCKER_HOST=x", "alias d=docker"]) == nil)
    }

    @Test func contextFollowsDockersOrder() {
        let contexts = [(name: "desktop-linux", socket: "/dd.sock"), (name: "orbstack", socket: "/orb.sock")]
        func pick(_ environment: [String: String], saved: String? = "desktop-linux", host: String? = nil) -> String {
            SetupPlan.currentContext(environment: environment, saved: saved, hostSocket: host, contexts: contexts)
        }
        #expect(pick([:]) == "desktop-linux")
        #expect(pick([:], saved: nil) == "default")
        #expect(pick(["DOCKER_CONTEXT": "orbstack"]) == "orbstack")
        // DOCKER_HOST beats the saved context. A context with the same socket is the engine in use; otherwise it is "default".
        #expect(pick(["DOCKER_HOST": "unix:///orb.sock"], host: "/orb.sock") == "orbstack")
        #expect(pick(["DOCKER_HOST": "unix:///other.sock"], host: "/other.sock") == "default")
        // DOCKER_CONTEXT beats DOCKER_HOST.
        #expect(pick(["DOCKER_CONTEXT": "desktop-linux", "DOCKER_HOST": "unix:///orb.sock"], host: "/orb.sock") == "desktop-linux")
        #expect(pick(["DOCKER_HOST": "tcp://remote:2375"]) == "default")
    }

    @Test func terminalCommandCarriesTheFlagsThatWork() {
        #expect(SetupPlan.terminalCommand(cli: "~/.local/bin/noodle", download: true, addPath: true, useDefault: true)
                == "~/.local/bin/noodle setup --tools --path --use")
        #expect(SetupPlan.terminalCommand(cli: "noodle", download: false, addPath: false, useDefault: false) == "noodle setup --no-use")
        #expect(SetupPlan.terminalCommand(cli: "~/Downloads/Noodle App/noodle", download: true, addPath: false, useDefault: false)
                == "~/'Downloads/Noodle App/noodle' setup --tools --no-use")
    }

    // MARK: import

    @Test func importCountsComeFromTheCLI() {
        let output = "image alpine:latest: skipped, name exists\nvolume data: copied\ndone: 1 copied, 2 unchanged or skipped, 0 failed\n"
        #expect(ImportOutcome.parse(output) == ImportOutcome(copied: 1, unchanged: 2, failed: 0))
        #expect(ImportOutcome.parse("nothing here") == nil)
        #expect(ImportOutcome(copied: 3, unchanged: 0, failed: 0).note(from: "Docker Desktop") == "Copied 3 items from Docker Desktop.")
        #expect(ImportOutcome(copied: 1, unchanged: 1, failed: 0).note(from: "OrbStack")
                == "Copied 1 item from OrbStack. 1 was already there or skipped.")
        // A conflict that was skipped must not read as copied.
        #expect(ImportOutcome(copied: 0, unchanged: 4, failed: 0).note(from: "Colima")
                == "Nothing new to copy from Colima. 4 were already there or skipped.")
        #expect(ImportOutcome(copied: 0, unchanged: 0, failed: 0).note(from: "Colima") == "Colima had nothing to copy.")
    }

    @Test func perItemResultsSeparateUnchangedAndSkipped() {
        let output = "image alpine:latest: already present and identical\nvolume db: skipped (exists)\n"
            + "done: 0 copied, 2 unchanged or skipped, 0 failed\n"
        let outcome = ImportOutcome.parse(output)
        #expect(outcome == ImportOutcome(copied: 0, unchanged: 1, failed: 0, skipped: 1))
        #expect(outcome?.note(from: "OrbStack") == "No items were copied from OrbStack. 1 item was already there. Skipped 1 item.")
    }

    @Test func importFailureKeepsItsCause() {
        let ok = "done: 3 copied, 0 unchanged or skipped, 0 failed"
        #expect(SetupVerdict.importResult(code: 0, output: ok) == nil)
        #expect(SetupVerdict.importResult(code: 0, output: "") == .importFailed("The import did not report a result. Try again, or skip it."))
        let failed = "volume data: FAILED copy stopped\ndone: 2 copied, 0 unchanged or skipped, 1 failed"
        #expect(SetupVerdict.importResult(code: 1, output: failed) == .importFailed("1 item didn’t copy. volume data: FAILED copy stopped"))
        // Exit 0 with a failed item is still a failure.
        #expect(SetupVerdict.importResult(code: 0, output: failed) != nil)
        #expect(SetupVerdict.importResult(code: 1, output: "noodle: import: cannot reach the source engine") == .importFailed("import: cannot reach the source engine"))
        #expect(SetupVerdict.importResult(code: 124, output: "Command timed out.") == .importFailed("It took too long."))
        #expect(SetupProblem.importFailed("x.").advice == "x. Nothing was removed from your other engine.")
    }

    // MARK: verdicts and wording

    @Test func aBrokenDockerAheadOnPathFails() {
        var facts = SetupFacts(dockerPath: "/d", daemonUp: true, dockerReachesNoodle: true, pathApplied: true)
        #expect(SetupVerdict.evaluate(code: 0, output: "", facts: facts) == nil)
        facts.pathConflict = "~/.local/bin/docker"
        #expect(SetupVerdict.evaluate(code: 0, output: "", facts: facts) == .pathBlocked("~/.local/bin/docker"))
        #expect(SetupProblem.pathBlocked("~/.local/bin/docker").title == "~/.local/bin/docker doesn’t run")
    }

    @Test func downloadWordingMatchesWhatHappened() {
        // Downloads are all checked before any is installed, so this claim holds; it must not say more.
        let advice = SetupProblem.brokenDownload.advice
        #expect(advice.contains("nothing from this download was installed"))
        #expect(SetupProblem.stopped("Nothing was installed.").title == "You stopped setup")
        for problem in [SetupProblem.brokenDownload, .pathBlocked("p"), .importFailed("d"), .stopped("s")] {
            #expect(!(problem.title + problem.advice).contains("—"))
        }
    }
}
