import Foundation
import NoodleCore

/// Developer commands stay local: reading a console never starts the daemon.
func cmdDebug(_ args: [String]) {
    switch args.first {
    case "boot-console": debugBootConsole(Array(args.dropFirst()))
    case "run": debugRawRun(Array(args.dropFirst()))
    case "bench": cmdBench(Array(args.dropFirst()))
    default: usageDie("usage: noodle debug boot-console [--disable] | run <rootfs-dir|stored-image> <command> [args...] | bench [--run [IMAGE]]")
    }
}

private func debugBootConsole(_ args: [String]) {
    guard args.isEmpty || args == ["--disable"] else {
        usageDie("usage: noodle debug boot-console [--disable]")
    }
    let fm = FileManager.default
    let marker = URL(fileURLWithPath: paths.vmLog.path + ".enabled")
    do {
        if args == ["--disable"] {
            if fm.fileExists(atPath: marker.path) { try fm.removeItem(at: marker) }
            err("Boot console capture disabled for the next VM boot.")
            return
        }
        try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: marker.path) {
            try Data().write(to: marker, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }
        guard fm.fileExists(atPath: paths.vmLog.path) else {
            err("Boot console capture enabled for the next VM boot. No console has been captured yet.")
            return
        }
        let handle = try FileHandle(forReadingFrom: paths.vmLog)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        if let bytes = try handle.read(upToCount: 262_144) { FileHandle.standardOutput.write(bytes) }
    } catch { die("cannot read boot console: \(error.localizedDescription)") }
}

/// Replace this unentitled CLI with the signed Virtualization.framework helper.
/// exec preserves stdio, signals and the helper's exit code without an idle parent.
func debugRawRun(_ args: [String]) -> Never {
    guard args.count >= 2, args.first?.hasPrefix("-") == false else {
        usageDie("usage: noodle debug run <rootfs-dir|stored-image> <command> [args...]")
    }
    let directory = URL(fileURLWithPath: selfDirectory())
    let candidates = [directory.appendingPathComponent("noodle-machine"),
                      directory.deletingLastPathComponent().appendingPathComponent("MacOS/noodle-machine")]
    guard let helper = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        die("signed VM executable not found next to noodle; reinstall Noodle", code: 127)
    }
    guard let resources = paths.resourcesDirectory else { die("cannot locate Noodle resources; reinstall Noodle") }
    let arguments = [helper.path, "raw-run", "--home", paths.root.path, "--resources", resources.path,
                     "--kernel", paths.kernel.path, "--initramfs", paths.initramfs.path, "--"] + args
    var pointers = arguments.map { strdup($0) }
    pointers.append(nil)
    execv(helper.path, &pointers)
    die("cannot launch noodle-machine: \(String(cString: strerror(errno)))", code: 126)
}
