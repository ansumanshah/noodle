import Foundation

/// Stage, install, confirm and roll back. Nothing here runs unless a person or the launch rule asks.
public enum UpdateInstaller {
    /// A launch that finds the new app still unconfirmed this many times rolls back.
    public static let maxUnconfirmedLaunches = 2

    // MARK: stage

    /// Extract the verified zip, validate the bundle, record it as staged.
    public static func stage(zip: URL, feed: UpdateFeed, current: URL, paths: NoodlePaths) throws -> UpdateState {
        let fm = FileManager.default
        let dir = UpdateStore.staging(paths).appendingPathComponent("\(feed.build)", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
            let items = try fm.contentsOfDirectory(atPath: dir.path).filter { $0 != "__MACOSX" }
            guard items == ["Noodle.app"] else { throw UpdateError.badBundle("archive must contain exactly Noodle.app") }
            let app = dir.appendingPathComponent("Noodle.app")
            try validate(app: app, feed: feed, current: current)
            let state = UpdateState(phase: .staged, version: feed.version, build: feed.build, stagedApp: app.path)
            try UpdateStore.save(state, paths)
            return state
        } catch { try? fm.removeItem(at: dir); throw error }
    }

    /// Same bundle id, the signed version and build, a valid sealed signature, and the same signing
    /// team as the app being replaced (ad-hoc builds compare as equal to each other).
    public static func validate(app: URL, feed: UpdateFeed, current: URL) throws {
        func info(_ u: URL) -> [String: Any]? { NSDictionary(contentsOf: u.appendingPathComponent("Contents/Info.plist")) as? [String: Any] }
        guard let new = info(app) else { throw UpdateError.badBundle("no Info.plist") }
        if let old = info(current), old["CFBundleIdentifier"] as? String != new["CFBundleIdentifier"] as? String {
            throw UpdateError.badBundle("bundle identifier changed")
        }
        guard new["CFBundleShortVersionString"] as? String == feed.version,
              (new["CFBundleVersion"] as? String).flatMap(Int.init) == feed.build else {
            throw UpdateError.badBundle("version does not match the signed feed")
        }
        try verifySignature(app: app, current: current)
    }

    /// Sealed signature plus same team as `current`. Re-run at install: state.json and the staged bundle are only files on disk.
    static func verifySignature(app: URL, current: URL) throws {
        let check = try? run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        if check == nil { throw UpdateError.signatureCheckFailed("codesign --verify rejected the bundle") }
        let newTeam = team(of: app), oldTeam = team(of: current)
        guard newTeam == oldTeam else { throw UpdateError.signatureCheckFailed("signing team \(newTeam ?? "none") differs from \(oldTeam ?? "none")") }
    }

    static func team(of app: URL) -> String? {
        let out = (try? run("/usr/bin/codesign", ["-d", "--verbose=2", app.path])) ?? ""
        return out.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }.flatMap { $0 == "not set" ? nil : $0 }
    }

    // MARK: install / confirm / rollback

    /// Swap the staged app over `target`. The swap is a single atomic replace; the old app is kept
    /// under `<root>/update/previous` until `confirm`.
    @discardableResult
    public static func install(target: URL, paths: NoodlePaths) throws -> UpdateState {
        try install(target: target, paths: paths, persist: UpdateStore.save)
    }

    static func build(of app: URL) -> Int? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])
            .flatMap { $0["CFBundleVersion"] as? String }.flatMap(Int.init)
    }

    /// The swap partner stays on the target's volume, so undo needs no copy or free disk space.
    static func swap(target: URL, with new: URL) throws {
        guard renamex_np(new.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateError.installFailed(String(cString: strerror(errno)))
        }
    }

    /// Called at app launch. Returns true when the previous version was restored (the caller should relaunch).
    @discardableResult
    public static func launchCheck(paths: NoodlePaths) -> Bool {
        if UpdateStore.load(paths)?.phase == .installing {
            return (try? recoverTransaction(paths: paths)) ?? false
        }
        guard var state = UpdateStore.load(paths), state.phase == .installed else { return false }
        removeTransactionApp(state)
        if state.launchAttempts >= maxUnconfirmedLaunches { return (try? rollback(paths: paths)) != nil }
        state.launchAttempts += 1
        try? UpdateStore.save(state, paths)
        return false
    }

    /// The new version proved healthy: drop the old app and the state.
    public static func confirm(paths: NoodlePaths) {
        if let s = UpdateStore.load(paths), s.phase == .installed {
            removeTransactionApp(s)
            try? FileManager.default.removeItem(at: UpdateStore.previous(paths))
            try? FileManager.default.removeItem(at: UpdateStore.staging(paths))
            try? FileManager.default.removeItem(at: UpdateStore.downloads(paths))
            UpdateStore.clear(paths)
        }
    }

    public static func rollback(paths: NoodlePaths) throws {
        _ = try preflightRollback(paths: paths)
        if UpdateStore.load(paths)?.phase == .installing {
            _ = try recoverTransaction(paths: paths)
            return
        }
        guard let state = UpdateStore.load(paths), state.phase == .installed,
              let target = state.target, let previous = state.previous,
              FileManager.default.fileExists(atPath: previous) else { throw UpdateError.noStagedUpdate }
        let t = URL(fileURLWithPath: target), p = URL(fileURLWithPath: previous)
        let sibling = t.deletingLastPathComponent().appendingPathComponent(".Noodle-old-\(UUID().uuidString.prefix(8)).app")
        try FileManager.default.copyItem(at: p, to: sibling)
        guard renamex_np(sibling.path, t.path, UInt32(RENAME_SWAP)) == 0 else {
            try? FileManager.default.removeItem(at: sibling)
            throw UpdateError.installFailed(String(cString: strerror(errno)))
        }
        try? FileManager.default.removeItem(at: sibling)   // the failed new version
        removeTransactionApp(state)
        try? FileManager.default.removeItem(at: UpdateStore.previous(paths))
        UpdateStore.clear(paths)
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) throws -> String {
        let (status, text) = try runCapturing(URL(fileURLWithPath: exe), args)
        guard status == 0 else { throw UpdateError.badBundle("\(URL(fileURLWithPath: exe).lastPathComponent): \(text.prefix(200))") }
        return text
    }
}
