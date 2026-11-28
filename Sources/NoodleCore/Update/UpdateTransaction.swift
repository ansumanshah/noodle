import Foundation

extension UpdateInstaller {
    /// Persist the intent before exchanging bundles, then commit installed state. Keeping the swap
    /// partner until commit lets a full disk failure restore the old app without allocating a copy.
    @discardableResult
    static func install(target: URL, paths: NoodlePaths,
                        persist: (UpdateState, NoodlePaths) throws -> Void) throws -> UpdateState {
        _ = try recoverTransaction(paths: paths)
        let fm = FileManager.default
        var state = try preflightInstall(target: target, paths: paths)
        let staged = state
        let sibling = target.deletingLastPathComponent().appendingPathComponent(".Noodle-new-\(UUID()).app")
        let keep = UpdateStore.previous(paths).appendingPathComponent("Noodle.app")
        var swapped = false
        var journaled = false
        do {
            try fm.copyItem(at: URL(fileURLWithPath: state.stagedApp), to: sibling)
            try? fm.removeItem(at: UpdateStore.previous(paths))
            try fm.createDirectory(at: UpdateStore.previous(paths), withIntermediateDirectories: true)
            try fm.copyItem(at: target, to: keep)
            guard try preflightInstall(target: target, paths: paths) == staged else {
                throw UpdateError.installFailed("the staged update changed; try again")
            }
            try verifySignature(app: sibling, current: target)
            state.phase = .installing; state.target = target.path; state.previous = keep.path
            state.transactionApp = sibling.path; state.launchAttempts = 0
            try persist(state, paths)
            journaled = true
            try swap(target: target, with: sibling)
            swapped = true
            state.phase = .installed
            try persist(state, paths)
        } catch {
            if swapped {
                do { try swap(target: target, with: sibling) }
                catch {
                    // Preserve the journal and both bundles for launchCheck or explicit rollback.
                    throw UpdateError.installFailed("could not restore the previous app: \(error.localizedDescription)")
                }
            }
            if journaled { try? persist(staged, paths) }
            // If resetting state failed, recovery still needs the journal's swap partner.
            if UpdateStore.load(paths)?.phase != .installing { try? fm.removeItem(at: sibling) }
            throw UpdateError.installFailed(error.localizedDescription)
        }
        try? fm.removeItem(at: sibling)
        return state
    }

    /// An interrupted transaction always restores the old app. Before the swap the partner is the
    /// new app; afterwards it is the old app. The target's build identifies which side survived.
    @discardableResult
    static func recoverTransaction(paths: NoodlePaths) throws -> Bool {
        guard var state = UpdateStore.load(paths), state.phase == .installing else { return false }
        guard let targetPath = state.target, let partnerPath = state.transactionApp else {
            throw UpdateError.installFailed("the update journal is incomplete")
        }
        let target = URL(fileURLWithPath: targetPath), partner = URL(fileURLWithPath: partnerPath)
        guard let current = build(of: target) else { throw UpdateError.badBundle("cannot read the installed build") }
        let restored = current == state.build
        if restored { try swap(target: target, with: partner) }
        state.phase = .staged; state.target = nil; state.previous = nil; state.transactionApp = nil
        state.launchAttempts = 0
        do { try UpdateStore.save(state, paths) }
        catch {
            // A completed restoration still needs a relaunch. Retain the journal and partner so a
            // later launch can retry cleanup without swapping the new app back into place.
            if restored { return true }
            throw error
        }
        try? FileManager.default.removeItem(at: partner)
        return restored
    }

    static func removeTransactionApp(_ state: UpdateState) {
        if let path = state.transactionApp { try? FileManager.default.removeItem(atPath: path) }
    }
}
