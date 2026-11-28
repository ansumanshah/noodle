import Foundation

/// One JSON document, sorted keys, `/` unescaped, no trailing text. Every `--json` output goes through it or the Encodable form.
func jsonLine(_ value: Any, pretty: Bool = false) -> String {
    let options: JSONSerialization.WritingOptions = pretty ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted] : [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { die("could not encode JSON") }
    return String(decoding: data, as: UTF8.self)
}

func jsonLine<T: Encodable>(encoding value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else { die("could not encode JSON") }
    return String(decoding: data, as: UTF8.self)
}

/// `noodle help`, `noodle help --json`, `noodle help <command>`.
func cmdHelp(_ args: [String]) {
    switch args {
    case [], ["--help"], ["-h"]: usage()
    case ["--json"]:
        do { out(String(decoding: try CommandTable.helpJSON(version: version), as: UTF8.self)) } catch { die("could not encode help: \(error)") }
    case let named where named.count == 1 && CommandTable.entries(named[0]).isEmpty == false:
        printGroupHelp(named[0])
    default: usageDie("usage: noodle help [--json | <command>]")
    }
}

/// Every group's help comes from the command table, so it cannot drift from what dispatch accepts.
func printGroupHelp(_ name: String) { out(CommandTable.groupHelp(name)) }

/// The arguments Noodle itself reads. Everything after `--`, and everything after `dev` or `debug run`, belongs to the
/// launched program, so a `--json` there must not move Noodle's own prose to stderr.
func ownArguments(_ argv: [String]) -> [String] {
    if argv.first == "dev" || Array(argv.prefix(2)) == ["debug", "run"] { return Array(argv.prefix(argv.first == "dev" ? 1 : 2)) }
    return Array(argv.prefix { $0 != "--" })
}

/// `noodle COMMAND ... --help` (or `GROUP SUB -h`) prints the command's help. Commands that hand their arguments to a
/// launched program, a machine or a model prompt keep them; so does everything after `--`.
func wantsNestedHelp(_ argv: [String]) -> Bool {
    guard argv.count >= 3, argv[0] != "dev", argv[0] != "help", commandGroups.contains(where: { $0.name == argv[0] }) else { return false }
    if argv.count == 3, CommandTable.hasSubcommands(argv[0]), ["--help", "-h"].contains(argv[2]) { return true }
    if [["debug", "run"], ["machine", "shell"], ["model", "run"]].contains(Array(argv.prefix(2))) { return false }
    return argv[1...].prefix { $0 != "--" }.contains("--help")
}
