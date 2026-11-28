import Foundation
import NoodleCore

/// Internal entry point used only by Docker plugin stubs. Leave argv, environment and stdin intact.
func cmdToolPlugin(_ args: [String]) -> Never {
    guard args.count >= 3, let metadata = LazyToolPlugin.metadata(args[0]) else { die("invalid Docker plugin invocation", code: 2) }
    let name = args[0]
    let original = Array(args.dropFirst(3))
    if original == ["docker-cli-plugin-metadata"] { out(metadata); exit(0) }
    let link = URL(fileURLWithPath: args[2])
    toolsInstall(names: [name], link: false, lazy: true, lazyLink: link, handoff: {
        let executable = Tools.pluginDirectory(paths).appendingPathComponent(name)
        if name == Tools.modelPlugin { prepareModelToolEnvironment(original: original) }
        var argv = ([link.path] + original).map { strdup($0) }
        argv.append(nil)
        execv(executable.path, &argv)
        die("cannot execute \(name): \(String(cString: strerror(errno)))", code: 126)
    })
    die("plugin handoff did not execute", code: 126)
}

func installPluginStubs(cli: URL, only names: Set<String>) throws {
    let fm = FileManager.default
    let installLock = try ToolInstallLock(paths: paths)
    defer { withExtendedLifetime(installLock) {} }
    // Repair every owned stub, including dangling links and stubs in another Docker config.
    let receipt = setupReceipt()
    for key in receipt.keys where key.hasPrefix("link:") {
        let link = URL(fileURLWithPath: String(key.dropFirst(5)))
        let name = link.lastPathComponent
        if LazyToolPlugin.metadata(name) != nil, LazyToolPlugin.ownsStub(link, name: name, paths: paths, receipt: receipt) {
            try writePluginStub(name, cli: cli)
        }
    }
    guard !names.isEmpty else { return }
    let directory = dockerConfigDirectory.appendingPathComponent("cli-plugins")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let existing = Set(try fm.contentsOfDirectory(atPath: directory.path))
    for name in Tools.linksToCreate(existing: existing) where names.contains(name) {
        let stub = try writePluginStub(name, cli: cli)
        let link = directory.appendingPathComponent(name)
        try fm.createSymbolicLink(at: link, withDestinationURL: stub)
        do { try setupRecordLink(link, target: stub.path) }
        catch { try? fm.removeItem(at: link); throw error }
        out("\(name): ready to download on first use")
    }
}

@discardableResult
func writePluginStub(_ name: String, cli: URL) throws -> URL {
    let directory = LazyToolPlugin.directory(paths)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stub = directory.appendingPathComponent(name)
    try LazyToolPlugin.script(name, cli: cli, paths: paths).write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    return stub
}
