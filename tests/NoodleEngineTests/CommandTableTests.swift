import Foundation
import Testing
@testable import noodle

@Suite struct CommandTableTests {
    /// Command names in main.swift's dispatch switch, read from the source so help cannot drift.
    private func dispatchedNames() throws -> Set<String> {
        let main = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/noodle/main.swift")
        let source = try String(contentsOf: main, encoding: .utf8)
        let switchStart = try #require(source.range(of: "switch argv.first {"))
        var names: Set<String> = []
        for line in source[switchStart.upperBound...].split(separator: "\n") where line.hasPrefix("case ") {
            let labels = line.dropFirst(4).prefix { $0 != ":" }
            for label in labels.split(separator: ",") {
                names.insert(label.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            }
        }
        return names
    }

    @Test func everyDispatchedCommandIsInTheTable() throws {
        let internalOnly: Set<String> = ["__tool-plugin", "agent", "--version", "-h", "--help", "nil"]
        let listed = Set(commandGroups.map(\.name))
        let dispatched = try dispatchedNames().subtracting(internalOnly)
        #expect(dispatched.count > 20)
        #expect(dispatched.subtracting(listed).isEmpty, "missing from the table: \(dispatched.subtracting(listed).sorted())")
        #expect(listed.subtracting(dispatched).isEmpty, "in the table but not dispatched: \(listed.subtracting(dispatched).sorted())")
    }

    @Test func everyEntryBelongsToAGroupAndEveryGroupHasEntries() {
        let names = Set(commandGroups.map(\.name))
        #expect(names.count == commandGroups.count)
        for entry in commandList { #expect(names.contains(entry.group), "\(entry.group)") }
        for group in commandGroups { #expect(!CommandTable.entries(group.name).isEmpty, "\(group.name)") }
    }

    @Test func helpJSONDecodesAndMatchesTheTable() throws {
        struct Doc: Decodable {
            struct Command: Decodable { let group: String; let subcommand: String?; let flags: [String]; let json: Bool; let prompts: Bool }
            let schemaVersion: Int
            let exitCodes: [String: String]
            let commands: [Command]
        }
        let doc = try JSONDecoder().decode(Doc.self, from: CommandTable.helpJSON(version: "1.2.3"))
        #expect(doc.schemaVersion == 1)
        #expect(Set(doc.exitCodes.keys) == ["0", "1", "2", "3"])
        #expect(doc.commands.count == commandList.count)
        #expect(doc.commands.contains { $0.group == "runners" && $0.subcommand == "status" && $0.json })
        #expect(doc.commands.contains { $0.group == "update" && $0.subcommand == "install" && $0.prompts })
    }

    @Test func helpTextListsEveryGroupAndSubcommand() {
        let top = CommandTable.topLevelHelp(version: "1.2.3")
        for group in commandGroups { #expect(top.contains(group.name), "\(group.name)") }
        let runners = CommandTable.groupHelp("runners")
        for entry in CommandTable.entries("runners") { #expect(runners.contains(entry.sub ?? ""), "\(entry.sub ?? "")") }
        #expect(top.contains("pause"))
        #expect(top.contains("proxy [set]") && top.contains("link [list|stop]"))
        #expect(top.contains("confirmation needed with no terminal"))
        #expect(CommandTable.groupHelp("status").contains("Usage: noodle status [--json]"))
    }

    @Test func jsonFlagIsListedForEveryJSONCommand() {
        for entry in commandList where entry.json {
            #expect(entry.flags.contains("--json") || entry.args.contains("--json"), "\(entry.group) \(entry.sub ?? "")")
        }
    }

    @Test func groupHelpIsTheTableRowsThenTheNotes() {
        let help = CommandTable.groupHelp("model")
        for entry in CommandTable.entries("model") { #expect(help.contains(entry.synopsis), "\(entry.synopsis)") }
        #expect(help.hasSuffix("The next request reloads an unloaded model."))
        #expect(CommandTable.groupHelp("pod").contains("Pods use container labels only."))
        #expect(!CommandTable.groupHelp("status").contains("\n\n\n"))
    }
}
