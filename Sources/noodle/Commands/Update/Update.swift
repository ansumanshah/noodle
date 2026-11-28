import Foundation
import NoodleCore

// noodle update: signed, staged app updates from the command line. Same engine as the app's Updates
// tab. Feed base and release key come from the app's Info.plist; flags or NOODLE_UPDATE_* override
// them (used by tests/update.sh with a local feed).

private func flag(_ name: String, _ args: [String]) -> String? {
    args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

private func bundleRoot() -> URL {   // Noodle.app when run from Contents/Helpers
    URL(fileURLWithPath: selfDirectory()).deletingLastPathComponent().deletingLastPathComponent()
}

private func updateConfig(_ args: [String]) -> UpdateConfig {
    let plist = UpdateConfig.load(infoPlist: (installedUpdateApp() ?? bundleRoot()).appendingPathComponent("Contents/Info.plist"))
    guard let base = flag("--feed-base", args) ?? env["NOODLE_UPDATE_FEED_BASE"] ?? plist?.feedBase,
          let key = flag("--public-key", args) ?? env["NOODLE_UPDATE_PUBLIC_KEY"] ?? plist?.publicKey else {
        die("updates are not configured (no feed base or release key in Info.plist)")
    }
    let build = flag("--current-build", args).flatMap(Int.init) ?? plist?.currentBuild ?? 0
    var c = UpdateConfig(feedBase: base, publicKey: key, currentBuild: build, currentVersion: plist?.currentVersion ?? "0")
    if let a = flag("--arch", args) { c.arch = a }
    return c
}

func cmdUpdate(_ args: [String]) {
    let usage = "usage: noodle update check [--json] | stage | install [--yes] | confirm | rollback [--yes] | status [--json]"
    guard let action = args.first, ["check", "stage", "install", "confirm", "rollback", "status"].contains(action) else {
        die(usage, code: 2)
    }
    // Feed, key, build, architecture and app overrides are development/test inputs.
    let valueFlags: Set<String> = ["--feed-base", "--public-key", "--current-build", "--arch", "--app"]
    var i = 1
    while i < args.count {
        let flag = args[i]
        if yesFlags.contains(flag), ["install", "rollback"].contains(action) { i += 1; continue }
        if flag == "--json", ["check", "status"].contains(action) { i += 1; continue }
        guard valueFlags.contains(flag), i + 1 < args.count, !args[i + 1].isEmpty, !args[i + 1].hasPrefix("-") else {
            die(usage, code: 2)
        }
        if flag == "--current-build" {
            guard let build = Int(args[i + 1]), build >= 0 else { die("--current-build requires a nonnegative integer", code: 2) }
        }
        i += 2
    }
    let target = flag("--app", args).map { URL(fileURLWithPath: $0) } ?? installedUpdateApp() ?? bundleRoot()
    switch args.first {
    case "check":
        let config = updateConfig(args)
        do {
            let found = try blocking({ try await UpdateClient.check(config) })
            if args.contains("--json") {
                jsonOut(updateCheckJSON(currentBuild: config.currentBuild, version: found?.0.version, build: found?.0.build)); return
            }
            guard let (feed, _) = found else { out("up to date (build \(config.currentBuild))"); return }
            out("update available: \(feed.version) (build \(feed.build))")
        } catch { die(error.localizedDescription) }
    case "stage":
        let config = updateConfig(args)
        do {
            guard let (feed, url) = try blocking({ try await UpdateClient.check(config) }) else { out("up to date"); return }
            let zip = try blocking { try await UpdateClient.download(feed, feedURL: url, into: UpdateStore.downloads(paths)) }
            let state = try UpdateInstaller.stage(zip: zip, feed: feed, current: target, paths: paths)
            out("staged \(state.version) (build \(state.build)); run `noodle update install`")
        } catch { die(error.localizedDescription) }
    case "install":
        do { try UpdateInstaller.preflightInstall(target: target, paths: paths) } catch { die(error.localizedDescription) }
        confirmInstall(yes: hasYes(args))
        installWithEngine(target: target)
    case "confirm":
        confirmUpdate(target: target)
    case "rollback":
        rollbackWithEngine(yes: hasYes(args))
    case "status":
        if args.contains("--json") {
            let s = UpdateStore.load(paths)
            jsonOut(updateStatusJSON(phase: s?.phase.rawValue, version: s?.version, build: s?.build, launchAttempts: s?.launchAttempts))
        } else if let s = UpdateStore.load(paths) { out("\(s.phase.rawValue) \(s.version) (build \(s.build)), unconfirmed launches \(s.launchAttempts)") } else { out("no update staged") }
    default: die("usage: noodle update check [--json] | stage | install [--yes] | confirm | rollback [--yes] | status [--json]", code: 2)
    }
}
