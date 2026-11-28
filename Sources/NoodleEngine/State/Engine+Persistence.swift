import Foundation
import OSLog
@_exported import NoodleCore
@_exported import NoodleImages
@_exported import NoodleVM

extension Engine {
    // MARK: persistence

    func loadState() throws {
        loadHostRoutes()
        do {
            _ = try FileManager.default.attributesOfItem(atPath: paths.stateFile.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return
        } catch {
            throw EngineError.internalError("Cannot access engine state at \(paths.stateFile.path): \(error)")
        }
        let st: EngineState
        do {
            let data = try Data(contentsOf: paths.stateFile)
            st = try JSONDecoder.engine.decode(EngineState.self, from: data)
        } catch {
            throw EngineError.internalError("Cannot read engine state at \(paths.stateFile.path): \(error). Restore or repair the file before starting Noodle.")
        }
        containers = Dictionary(st.containers.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        networks = Dictionary(st.networks.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        volumes = Dictionary(st.volumes.map { ($0.name, $0) }, uniquingKeysWith: { _, latest in latest })
        pendingRemovals = st.pending ?? PendingRemovals()
    }

    func scheduleSave() {
        refreshNames()
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250), tolerance: .milliseconds(150))
            await self?.flushState()
        }
    }

    func flushState() {
        saveScheduled = false
        do { try persistState() } catch {
            log.error("state save failed, retrying: \(String(describing: error))")
            // Retry after a delay (not a tight loop); later mutations also schedule a save.
            guard !saveScheduled else { return }
            saveScheduled = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5), tolerance: .seconds(1))
                await self?.flushState()
            }
        }
    }

    func persistState() throws {
        guard started else { return }
        var st = EngineState()
        st.containers = Array(containers.values)
        st.networks = Array(networks.values)
        st.volumes = Array(volumes.values)
        st.pending = pendingRemovals
        try ImageDurability.write(JSONEncoder.engine.encode(st), to: paths.stateFile)
    }
}
