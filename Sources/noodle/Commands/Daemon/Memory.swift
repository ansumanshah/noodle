import Darwin
import Foundation

func processFootprint(_ pid: Int32) -> UInt64? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return result == 0 ? info.ri_phys_footprint : nil
}

/// The recorded runner pid is a supervisor; the runtime holding the weights is a child in its group.
func processGroupFootprint(_ pid: Int32) -> UInt64? {
    var group = [pid_t](repeating: 0, count: 64)
    let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), &group, Int32(group.count * MemoryLayout<pid_t>.size))
    let pids = Set(group.prefix(max(0, Int(bytes)) / MemoryLayout<pid_t>.size).filter { $0 > 0 } + [pid])
    let sizes = pids.compactMap(processFootprint)
    return sizes.isEmpty ? nil : sizes.reduce(0, +)
}

private func processPath(_ pid: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
}

/// Footprint of the Virtualization.framework helper that runs noodled's VM; nil while it sleeps.
/// The helper is a launchd service, so its owner is found through the responsible pid.
func vmFootprint() -> UInt64? {
    typealias Responsible = @convention(c) (pid_t) -> pid_t
    guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
    let owner = unsafeBitCast(symbol, to: Responsible.self)
    var pids = [pid_t](repeating: 0, count: 4096)
    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    let bytes = pids.prefix(max(0, count)).filter {
        processPath($0).hasSuffix("com.apple.Virtualization.VirtualMachine")
            && processPath(owner($0)).hasSuffix("/noodled")
    }.compactMap(processFootprint)
    return bytes.isEmpty ? nil : bytes.reduce(0, +)
}

func memorySnapshot() -> [String: Any] {
    let model = ModelRunner(store: modelStore()).memory()
    return ["vmResidentBytes": vmFootprint() as Any? ?? NSNull(),
            "modelResidentBytes": model?.resident as Any? ?? NSNull(),
            "modelLastRequest": model?.lastRequest.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()]
}

func modelIdleLongEnough(lastRequest: Date?, now: Date, idleSeconds: Int) -> Bool {
    guard let lastRequest else { return false }
    return now.timeIntervalSince(lastRequest) >= Double(idleSeconds)
}

func memoryReclaimJSON(modelUnloaded: Bool, vmSlept: Bool, freedBytes: UInt64?) -> [String: Any] {
    ["schemaVersion": 1, "modelUnloaded": modelUnloaded, "vmSlept": vmSlept, "freedBytes": freedBytes as Any? ?? NSNull()]
}

private let memoryUsage = "usage: noodle memory reclaim [--idle SECONDS] [--json]"

private func sleepVM() -> Bool {
    let http = DockerHTTP(socketPath: socketPath, timeout: 30)
    guard ping(), let reply = try? http.request("POST", "/noodle/vm/sleep"),
          let body = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any] else { return false }
    return body["slept"] as? Bool == true
}

private func residentTotal(_ runner: ModelRunner) -> UInt64? {
    let parts = [vmFootprint(), runner.memory()?.resident].compactMap { $0 }
    return parts.isEmpty ? nil : parts.reduce(0, +)
}

func cmdMemory(_ args: [String]) {
    guard args.first == "reclaim" else { usageDie(memoryUsage) }
    var idle = 60, json = false
    var rest = args.dropFirst()
    while let arg = rest.popFirst() {
        if arg == "--json" {
            json = true
        } else if arg == "--idle", let value = rest.popFirst().flatMap({ Int($0) }), value >= 0 {
            idle = value
        } else {
            usageDie(memoryUsage)
        }
    }
    let runner = ModelRunner(store: modelStore())
    let before = residentTotal(runner)
    var unloaded = false
    if modelIdleLongEnough(lastRequest: runner.memory()?.lastRequest, now: Date(), idleSeconds: idle) {
        do {
            try stopModelRunnerIfPresent()
            unloaded = true
        } catch {
            note("could not unload the model: \(error.localizedDescription)")
        }
    }
    let slept = sleepVM()
    let after = residentTotal(runner) ?? 0
    let freed = before.map { $0 > after ? $0 - after : 0 }
    if json { jsonOut(memoryReclaimJSON(modelUnloaded: unloaded, vmSlept: slept, freedBytes: freed)); return }
    if unloaded { out("Model unloaded") }
    if slept { out("VM put to sleep") }
    out(unloaded || slept ? "Freed \((freed ?? 0) >> 20) MiB" : "Nothing to free")
}
