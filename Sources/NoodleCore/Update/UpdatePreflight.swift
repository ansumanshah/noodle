import Foundation

extension UpdateInstaller {
    /// Read-only checks run before stopping the engine and again by the installer after it stops.
    @discardableResult
    public static func preflightInstall(target: URL, paths: NoodlePaths) throws -> UpdateState {
        guard let state = UpdateStore.load(paths), state.phase == .staged,
              FileManager.default.fileExists(atPath: state.stagedApp) else { throw UpdateError.noStagedUpdate }
        guard let current = build(of: target) else { throw UpdateError.badBundle("cannot read the installed build") }
        guard state.build > current else { throw UpdateError.notNewer }
        return state
    }

    /// Rollback always acts on the journal's target, including when called by a retained helper.
    public static func preflightRollback(paths: NoodlePaths) throws -> URL {
        guard let state = UpdateStore.load(paths), let path = state.target else { throw UpdateError.noStagedUpdate }
        let target = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { throw UpdateError.noStagedUpdate }
        switch state.phase {
        case .installed:
            guard let previous = state.previous, build(of: URL(fileURLWithPath: previous)) != nil else {
                throw UpdateError.noStagedUpdate
            }
        case .installing:
            guard let current = build(of: target) else { throw UpdateError.badBundle("cannot read the installed build") }
            guard let partner = state.transactionApp else { throw UpdateError.installFailed("the update journal is incomplete") }
            if current == state.build, build(of: URL(fileURLWithPath: partner)) == nil {
                throw UpdateError.noStagedUpdate
            }
        case .staged: throw UpdateError.noStagedUpdate
        }
        return target
    }
}
