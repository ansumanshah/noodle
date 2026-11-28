import Foundation
import Testing
@testable import NoodleCore

@Suite struct RunnerDoctorTests {
    static let gb: Int64 = 1_000_000_000

    /// A Mac where every check passes, one Linux repo.
    static func healthy() -> RunnerDoctorProbes {
        var p = RunnerDoctorProbes()
        p.repos = [RunnerRepo(repo: "a/b", macos: false)]
        p.tokenPresent = true
        p.access = ["a/b": .ok]
        p.reachability = .ok
        p.freeDiskBytes = 200 * gb
        p.helperRunning = true
        p.agent = .ok
        p.runnerInstall = .installed
        p.engineAnswers = true
        p.sleep = RunnerSleepSettings(acSleepMinutes: 0, laptop: false)
        return p
    }

    static func level(_ id: String, _ p: RunnerDoctorProbes) -> DoctorLevel? {
        RunnerDoctor.findings(p).first { $0.id == id }?.level
    }

    @Test func healthyMacHasOnlyOk() {
        let f = RunnerDoctor.findings(Self.healthy())
        #expect(f.allSatisfy { $0.level == .ok })
        #expect(RunnerDoctor.exitCode(f) == 0)
        #expect(f.map(\.id).contains("macos-xcode") == false)
    }

    @Test func signInAndAccess() {
        var p = Self.healthy(); p.tokenPresent = false; p.access = [:]
        #expect(Self.level("github-signin", p) == .problem)
        p = Self.healthy(); p.access = ["a/b": .forbidden]
        #expect(Self.level("github-signin", p) == .problem)
        p.access = ["a/b": .network]
        #expect(Self.level("github-signin", p) == .warning)
        p.access = ["a/b": .unauthorized]
        #expect(RunnerDoctor.findings(p).first { $0.id == "github-signin" }?.fix != nil)
    }

    @Test func aProblemOnOneRepoOutranksAWarningOnAnother() {
        var p = Self.healthy()
        p.repos = [RunnerRepo(repo: "a/b", macos: false), RunnerRepo(repo: "c/d", macos: false)]
        p.access = ["a/b": .other(502), "c/d": .notFound]
        let f = RunnerDoctor.findings(p).first { $0.id == "github-signin" }
        #expect(f?.level == .problem && f?.message.contains("c/d") == true)
        #expect(RunnerDoctor.exitCode(RunnerDoctor.findings(p)) == 1)
    }

    @Test func freeSpaceIsTruncatedLikeTheHoldText() {
        var p = Self.healthy()
        p.freeDiskBytes = 9_600_000_000
        #expect(RunnerDoctor.findings(p).first { $0.id == "disk" }?.message == "9 GB free on the Noodle volume.")
        #expect(RunnerHold.disk(freeBytes: 9_600_000_000, needsBytes: RunnerHealth.holdBytes).text.contains("9 GB free"))
    }

    @Test func reachability() {
        var p = Self.healthy(); p.reachability = .noDNS
        #expect(Self.level("github-reachable", p) == .problem)
        p.reachability = .noHTTPS
        #expect(Self.level("github-reachable", p) == .problem)
    }

    @Test func diskThresholds() {
        var p = Self.healthy()
        p.freeDiskBytes = RunnerDoctor.diskWarningBytes - 1
        #expect(Self.level("disk", p) == .warning)
        p.freeDiskBytes = RunnerDoctor.diskProblemBytes - 1
        #expect(Self.level("disk", p) == .problem)
        p.freeDiskBytes = RunnerDoctor.diskWarningBytes
        #expect(Self.level("disk", p) == .ok)
        p.freeDiskBytes = nil
        #expect(Self.level("disk", p) == .warning)
    }

    @Test func helperAndAgent() {
        var p = Self.healthy(); p.helperRunning = false
        #expect(Self.level("helper", p) == .problem)
        p.repos = []
        #expect(Self.level("helper", p) == .warning)
        p = Self.healthy(); p.agent = .noRestart
        #expect(Self.level("helper", p) == .warning)
        p.agent = .missing
        #expect(Self.level("helper", p) == .warning)
    }

    @Test func runnerDownload() {
        var p = Self.healthy(); p.runnerInstall = .absentReachable
        #expect(Self.level("runner-download", p) == .ok)
        p.runnerInstall = .absentUnreachable
        #expect(Self.level("runner-download", p) == .warning)
        p.repos = [RunnerRepo(repo: "a/b", macos: true)]
        #expect(Self.level("runner-download", p) == .problem)
    }

    @Test func engine() {
        var p = Self.healthy(); p.engineAnswers = false
        #expect(Self.level("engine", p) == .problem)
        p.repos = []
        #expect(Self.level("engine", p) == .warning)
    }

    @Test func sleep() {
        var p = Self.healthy()
        p.sleep = RunnerSleepSettings(acSleepMinutes: 10, laptop: false)
        #expect(Self.level("sleep", p) == .warning)
        p.sleep = RunnerSleepSettings(acSleepMinutes: 0, laptop: true)
        #expect(Self.level("lid", p) == .warning)
        p.sleep = nil
        #expect(Self.level("sleep", p) == .warning)
    }

    @Test func pmsetParsing() {
        let text = """
        Battery Power:
         sleep                1
         displaysleep         2
        AC Power:
         sleep                0
         displaysleep         10
        """
        let s = RunnerSleepSettings(pmsetCustom: text)
        #expect(s.acSleepMinutes == 0 && s.laptop)
        let desktop = RunnerSleepSettings(pmsetCustom: "AC Power:\n sleep                30\n displaysleep 10\n")
        #expect(desktop.acSleepMinutes == 30 && !desktop.laptop)
    }

    @Test func macosChecksOnlyWhenEnabled() {
        var p = Self.healthy(); p.repos = [RunnerRepo(repo: "a/b", macos: true)]
        p.xcode = RunnerXcodeState(selectedPath: nil, licenseAccepted: false, firstLaunchDone: false)
        p.autoLogin = false
        #expect(Self.level("macos-xcode", p) == .problem)
        #expect(Self.level("macos-autologin", p) == .warning)
        p.xcode = RunnerXcodeState(selectedPath: "/Library/Developer/CommandLineTools", licenseAccepted: false, firstLaunchDone: false)
        #expect(Self.level("macos-xcode", p) == .problem)
        #expect(RunnerDoctor.findings(p).first { $0.id == "macos-xcode" }?.message.hasPrefix("No Xcode is selected.") == true)
        p.xcode = RunnerXcodeState(selectedPath: "/Applications/Xcode.app/Contents/Developer", licenseAccepted: false, firstLaunchDone: true)
        #expect(Self.level("macos-xcode", p) == .problem)
        p.xcode = RunnerXcodeState(selectedPath: "/Applications/Xcode.app/Contents/Developer", licenseAccepted: true, firstLaunchDone: false)
        #expect(Self.level("macos-xcode", p) == .problem)
        p.xcode = RunnerXcodeState(selectedPath: "/Applications/Xcode.app/Contents/Developer", licenseAccepted: true, firstLaunchDone: true)
        p.autoLogin = true
        #expect(Self.level("macos-xcode", p) == .ok && Self.level("macos-autologin", p) == .ok)
    }

    @Test func exitCodeFollowsProblems() {
        var p = Self.healthy(); p.sleep = nil
        #expect(RunnerDoctor.exitCode(RunnerDoctor.findings(p)) == 0)
        p.engineAnswers = false
        #expect(RunnerDoctor.exitCode(RunnerDoctor.findings(p)) == 1)
    }

    @Test func rateLimitIsItsOwnWarning() {
        var p = Self.healthy(); p.access = ["a/b": .limited]
        let f = RunnerDoctor.findings(p).first { $0.id == "github-signin" }
        #expect(f?.level == .warning && f?.message.contains("limiting") == true)
    }

    @Test func helperLoginItemProblemsAreNamed() {
        var p = Self.healthy()
        for state in [RunnerAgentState.badProgram, .noRunAtLoad] {
            p.agent = state
            #expect(Self.level("helper", p) == .warning)
        }
    }

    @Test func aMissingXcodeIsNotALicenceProblem() {
        var p = Self.healthy()
        p.repos = [RunnerRepo(repo: "a/b", macos: true)]
        p.autoLogin = true
        p.xcode = RunnerXcodeState(selectedPath: "/Applications/Xcode.app/Contents/Developer", licenseAccepted: false, firstLaunchDone: false,
                                   selectedPathExists: false)
        let f = RunnerDoctor.findings(p).first { $0.id == "macos-xcode" }
        #expect(f?.message == "The selected Xcode is no longer on disk.")
        p.autoLogin = nil
        #expect(Self.level("macos-autologin", p) == .warning)
    }

    @Test func aHoldOrCriticalMemoryIsAProblem() {
        var p = Self.healthy(); p.hold = RunnerHold.memory(.critical).text
        #expect(Self.level("hold", p) == .problem)
        p.hold = nil; p.memoryCritical = true
        #expect(Self.level("hold", p) == .problem)
        p.memoryCritical = false
        #expect(Self.level("hold", p) == nil)
        p.memoryCritical = true; p.helperRunning = false  // nothing holds jobs while the helper is off
        #expect(Self.level("hold", p) == nil)
    }

    @Test func aDiskHoldIsTheDiskFindingAlone() {
        var p = Self.healthy(); p.hold = RunnerHold.disk(freeBytes: 30 * RunnerHealth.gigabyte, needsBytes: 40 * RunnerHealth.gigabyte).text
        let f = RunnerDoctor.findings(p)
        #expect(f.filter { $0.id == "disk" }.count == 1 && f.first { $0.id == "disk" }?.level == .problem)
        #expect(f.first { $0.id == "disk" }?.message.hasPrefix("Holding new jobs: 30 GB free") == true)
        #expect(!f.contains { $0.id == "hold" })
    }

    @Test func anUnreadableRepoListIsAProblem() {
        var p = Self.healthy()
        let why = RunnerStoreError.unreadable("/x/repos.json", "bad JSON").localizedDescription
        p.reposError = why
        let found = RunnerDoctor.findings(p).first(where: { $0.id == "repos" })
        #expect(found?.level == .problem && found?.message == why)
        #expect(Self.level("repos", Self.healthy()) == nil)
    }

    @Test func sleepFixNamesTheRightSettingsPane() {
        var p = Self.healthy(); p.sleep = RunnerSleepSettings(acSleepMinutes: 10, laptop: false)
        #expect(RunnerDoctor.findings(p).first { $0.id == "sleep" }?.fix?.contains("Energy") == true)
        p.sleep = RunnerSleepSettings(acSleepMinutes: 10, laptop: true)
        #expect(RunnerDoctor.findings(p).first { $0.id == "sleep" }?.fix?.contains("Battery, Options") == true)
    }
}
