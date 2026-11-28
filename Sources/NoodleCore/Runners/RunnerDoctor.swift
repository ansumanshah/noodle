import Foundation

public enum DoctorLevel: String, Codable, Sendable { case ok, warning, problem }

public struct DoctorFinding: Codable, Equatable, Sendable {
    public var id: String
    public var level: DoctorLevel
    public var message: String
    /// The one-line fix, when there is something to do.
    public var fix: String?
}

public enum RunnerRepoAccess: Equatable, Sendable {
    case ok, unauthorized, forbidden, notFound, network, limited, other(Int)
}

public enum RunnerReachability: Equatable, Sendable { case ok, noDNS, noHTTPS }
public enum RunnerAgentState: Equatable, Sendable {
    /// `badProgram`: the program the login item starts is missing or not executable. `noRunAtLoad`: it does not start at login.
    case missing, notLoaded, noRestart, badProgram, noRunAtLoad, ok
}
public enum RunnerInstallState: Equatable, Sendable { case installed, absentReachable, absentUnreachable }

public struct RunnerSleepSettings: Equatable, Sendable {
    /// Minutes of idle before the Mac sleeps on power; 0 means never.
    public var acSleepMinutes: Int?
    public var laptop: Bool
    public init(acSleepMinutes: Int?, laptop: Bool) { self.acSleepMinutes = acSleepMinutes; self.laptop = laptop }

    /// Reads `pmset -g custom`: a "Battery Power:" section means a laptop, `sleep` under "AC Power:" is the idle sleep time.
    public init(pmsetCustom text: String) {
        var section = "", minutes: Int?, battery = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") { section = String(line.dropLast()); battery = battery || section == "Battery Power"; continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            if section == "AC Power", parts.count >= 2, parts[0] == "sleep" { minutes = Int(parts[1]) }
        }
        self.init(acSleepMinutes: minutes, laptop: battery)
    }
}

public struct RunnerXcodeState: Equatable, Sendable {
    public var selectedPath: String?
    public var licenseAccepted: Bool
    public var firstLaunchDone: Bool
    /// False when `xcode-select` points at an Xcode that is no longer on disk.
    public var selectedPathExists: Bool
    public init(selectedPath: String?, licenseAccepted: Bool, firstLaunchDone: Bool, selectedPathExists: Bool = true) {
        self.selectedPath = selectedPath; self.licenseAccepted = licenseAccepted; self.firstLaunchDone = firstLaunchDone
        self.selectedPathExists = selectedPathExists
    }
}

/// What the probes found on this Mac. Nil means a probe could not run.
public struct RunnerDoctorProbes: Sendable {
    public var repos: [RunnerRepo] = []
    public var tokenPresent = false
    public var access: [String: RunnerRepoAccess] = [:]
    public var reachability: RunnerReachability = .ok
    public var freeDiskBytes: Int64?
    public var helperRunning = false
    public var agent: RunnerAgentState = .missing
    public var runnerInstall: RunnerInstallState = .installed
    public var engineAnswers = false
    public var sleep: RunnerSleepSettings?
    public var xcode: RunnerXcodeState?
    public var autoLogin: Bool?
    /// The last failed runner start, read from the helper's state while it runs.
    public var startFailures: [RunnerStartFailure] = []
    public var logDirectory = URL(fileURLWithPath: "/")
    /// The helper's published hold, read while it runs.
    public var hold: String?
    /// Why repos.json could not be read, worded as the commands that change it say it.
    public var reposError: String?
    public var memoryCritical = false
    public init() {}
}

/// The findings are a pure function of the probes, so they are tested without touching the machine.
public enum RunnerDoctor {
    public static let diskWarningBytes: Int64 = RunnerHealth.resumeBytes
    public static let diskProblemBytes: Int64 = RunnerHealth.holdBytes

    public static func exitCode(_ findings: [DoctorFinding]) -> Int32 { findings.contains { $0.level == .problem } ? 1 : 0 }

    public static func findings(_ p: RunnerDoctorProbes) -> [DoctorFinding] {
        var f: [DoctorFinding] = []
        func add(_ id: String, _ level: DoctorLevel, _ message: String, fix: String? = nil) {
            f.append(DoctorFinding(id: id, level: level, message: message, fix: fix))
        }
        let hasRepos = !p.repos.isEmpty
        let macos = p.repos.contains { $0.macos }

        // GitHub sign-in and permission to register runners.
        if !p.tokenPresent {
            add("github-signin", .problem, "No GitHub sign-in found.", fix: "Sign in under Settings and turn on \"Also use for git clone and runners\".")
        } else {
            let bad = p.repos.compactMap { r -> (String, RunnerRepoAccess)? in
                guard let a = p.access[r.repo], a != .ok else { return nil }
                return (r.repo, a)
            }
            // A problem on one repo outranks a warning on another, so doctor still exits 1.
            let problem: [RunnerRepoAccess] = [.unauthorized, .forbidden, .notFound]
            if let (repo, a) = bad.first(where: { problem.contains($0.1) }) ?? bad.first(where: { $0.1 != .network }) ?? bad.first {
                switch a {
                case .unauthorized: add("github-signin", .problem, "GitHub did not accept the saved sign-in.", fix: "Sign in again under Settings.")
                case .forbidden, .notFound:
                    add("github-signin", .problem, "The saved sign-in cannot register runners for \(repo). It needs the repo scope and admin access to the repo.",
                        fix: "Use a token with the repo scope for an account that administers \(repo).")
                case .network: add("github-signin", .warning, "Could not confirm the sign-in for \(repo).", fix: "Run this again when GitHub is reachable.")
                case .limited: add("github-signin", .warning, "GitHub is limiting requests from this sign-in, so access to \(repo) was not checked.",
                                   fix: "Run this again after the limit resets, usually within an hour.")
                default: add("github-signin", .warning, "GitHub gave an unexpected answer for \(repo).", fix: "Run this again in a few minutes.")
                }
            } else {
                add("github-signin", .ok, hasRepos ? "GitHub sign-in can register runners for \(p.repos.count) repo(s)." : "GitHub sign-in is present. No repos added yet.")
            }
        }

        switch p.reachability {
        case .ok: add("github-reachable", .ok, "GitHub is reachable.")
        case .noDNS: add("github-reachable", .problem, "Cannot look up api.github.com.", fix: "Check this Mac's network and DNS settings.")
        case .noHTTPS: add("github-reachable", .problem, "api.github.com does not answer over HTTPS.", fix: "Check the network, VPN or proxy.")
        }

        if let why = p.reposError { add("repos", .problem, why) }

        // The helper's hold: a disk hold is the disk finding, a memory hold its own.
        let memoryHold = p.hold == RunnerHold.memory(.critical).text
        if let hold = p.hold, !memoryHold {
            add("disk", .problem, hold + ".", fix: "Delete unused images and volumes, or other files on this volume. Jobs start again by themselves once there is room.")
        } else if let free = p.freeDiskBytes {
            let text = "\(free / RunnerHealth.gigabyte) GB free on the Noodle volume."  // truncated, as the hold text
            if free < diskProblemBytes { add("disk", .problem, text, fix: "New jobs are held until there is more room. Delete unused images and volumes, or other files on this volume.") }
            else if free < diskWarningBytes { add("disk", .warning, text, fix: "Free space soon; jobs fail when the disk fills.") }
            else { add("disk", .ok, text) }
        } else { add("disk", .warning, "Could not read free disk space.") }

        if p.helperRunning {
            switch p.agent {
            case .ok: add("helper", .ok, "The runners helper is running and restarts after a crash.")
            case .missing: add("helper", .warning, "The runners helper is running but will not come back after a crash or restart.", fix: "Run `noodle runners stop`, then `noodle runners start`.")
            case .notLoaded: add("helper", .warning, "The runners helper is running but its login item is not loaded.", fix: "Run `noodle runners stop`, then `noodle runners start`.")
            case .noRestart: add("helper", .warning, "The runners helper will not restart after a crash.", fix: "Run `noodle runners stop`, then `noodle runners start`.")
            case .badProgram: add("helper", .warning, "The runners helper's login item points at a program that is missing or not executable.", fix: "Run `noodle runners stop`, then `noodle runners start`.")
            case .noRunAtLoad: add("helper", .warning, "The runners helper does not start at login.", fix: "Run `noodle runners stop`, then `noodle runners start`.")
            }
        } else if hasRepos {
            add("helper", .problem, "The runners helper is not running, so no jobs are picked up.", fix: "Run `noodle runners start`.")
        } else {
            add("helper", .warning, "The runners helper is off and no repos are added.", fix: "Run `noodle runners add <owner/repo>`.")
        }

        switch p.runnerInstall {
        case .installed: add("runner-download", .ok, "The pinned GitHub runner is installed.")
        case .absentReachable: add("runner-download", .ok, "The pinned GitHub runner downloads on the first macOS job and is checked against its SHA-256.")
        case .absentUnreachable:
            add("runner-download", macos ? .problem : .warning, "The pinned GitHub runner is not installed and cannot be downloaded now.",
                fix: "Check access to github.com, then run this again.")
        }

        for s in p.startFailures {
            add("start-failure-\(s.kind.rawValue)", .problem, s.line(logDirectory: p.logDirectory), fix: "Fix the cause shown in the log. Runners try again by themselves.")
        }

        if p.helperRunning, memoryHold || p.memoryCritical {
            add("hold", .problem, memoryHold ? (p.hold ?? "") + "." : "This Mac is critically low on memory, so the helper holds new jobs.",
                fix: "Quit apps or stop containers you do not need. Jobs start again by themselves once this clears.")
        }

        if p.engineAnswers { add("engine", .ok, "The container engine answers.") }
        else { add("engine", hasRepos ? .problem : .warning, "The container engine does not answer, so Linux jobs cannot run.", fix: "Run `noodle start`.") }

        if let s = p.sleep {
            if let m = s.acSleepMinutes, m > 0 {
                add("sleep", .warning, "This Mac sleeps after \(m) min idle on power. Jobs that queue while it sleeps wait until it wakes.",
                    fix: s.laptop
                        ? "In System Settings, Battery, Options, turn on \"Prevent automatic sleeping on power adapter when the display is off\", or run `sudo pmset -c sleep 0`."
                        : "In System Settings, Energy, turn on \"Prevent automatic sleeping when the display is off\", or run `sudo pmset -c sleep 0`.")
            } else if s.acSleepMinutes == nil { add("sleep", .warning, "Could not read the sleep setting.") }
            else { add("sleep", .ok, "This Mac does not sleep while idle on power.") }
            if s.laptop {
                add("lid", .warning, "A closed lid sleeps this laptop and stops jobs unless it is on power with an external display.",
                    fix: "Keep the lid open, or connect power and a display.")
            }
        } else { add("sleep", .warning, "Could not read power settings.") }

        if macos {
            if let x = p.xcode {
                if !(x.selectedPath?.contains(".app/") ?? false) {
                    let tools = x.selectedPath != nil ? " Only the Command Line Tools are selected." : ""
                    add("macos-xcode", .problem, "No Xcode is selected.\(tools)", fix: "Install Xcode, then run `sudo xcode-select -s /Applications/Xcode.app`.")
                }
                else if !x.selectedPathExists {
                    add("macos-xcode", .problem, "The selected Xcode is no longer on disk.", fix: "Run `sudo xcode-select -s` with the Xcode you use.")
                }
                else if !x.licenseAccepted { add("macos-xcode", .problem, "The Xcode licence is not accepted.", fix: "Run `sudo xcodebuild -license accept`.") }
                else if !x.firstLaunchDone { add("macos-xcode", .problem, "Xcode first-launch setup is not done.", fix: "Run `sudo xcodebuild -runFirstLaunch`.") }
                else { add("macos-xcode", .ok, "Xcode is selected, its licence is accepted and setup is done.") }
            } else { add("macos-xcode", .warning, "Could not check Xcode.") }
            switch p.autoLogin {
            case true?: add("macos-autologin", .ok, "This Mac logs in automatically after a restart.")
            case false?:
                add("macos-autologin", .warning, "After a restart this Mac waits at the login screen, so macOS jobs do not run until you sign in. Automatic login is off, and it is unavailable while FileVault is on.",
                    fix: "Turn on automatic login in System Settings, Users & Groups, if you want jobs to resume unattended.")
            case nil: add("macos-autologin", .warning, "Could not check automatic login.")
            }
        }
        return f
    }
}

extension GitHubRunnersAPI {
    /// Whether the token can manage this repo's runners: listing them needs admin access and the repo scope.
    public func runnerAccess(_ repo: String) async -> RunnerRepoAccess {
        do { _ = try await json(request("/repos/\(repo)/actions/runners?per_page=1")); return .ok }
        catch RunnerAPIError.unauthorized { return .unauthorized }
        catch RunnerAPIError.forbidden { return .forbidden }
        catch RunnerAPIError.network { return .network }
        catch RunnerAPIError.limited { return .limited }
        catch RunnerAPIError.http(404) { return .notFound }
        catch RunnerAPIError.http(let c) { return .other(c) }
        catch { return .other(0) }
    }
}
