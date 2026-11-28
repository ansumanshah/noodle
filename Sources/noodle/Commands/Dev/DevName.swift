import Foundation
import NoodleCore
import Darwin

extension DevCommand {
    private static func label(_ raw: String) -> String {
        var value = ""
        for character in raw.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) { value.append(character) }
            else if !value.isEmpty && value.last != "-" { value.append("-") }
        }
        return String(value.prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func inferredHost(_ explicit: String?) throws -> String {
        var chosenName: String?
        var domain = "localhost"
        if let explicit {
            let name: String
            if explicit.hasSuffix("." + LocalNameDomain.brandedSuffix) {
                domain = LocalNameDomain.brandedSuffix
                name = String(explicit.dropLast(domain.count + 1))
            } else {
                name = explicit.hasSuffix(".localhost") ? String(explicit.dropLast(10)) : explicit
            }
            let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty && label($0) == $0 }), name.utf8.count <= 252 - domain.utf8.count else {
                throw CLIError("Dev names use lowercase DNS labels, for example api.myapp.", exitCode: ExitCode.usage)
            }
            chosenName = name
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let gitRoot = git(["rev-parse", "--show-toplevel"])
        let gitDir = git(["rev-parse", "--path-format=absolute", "--git-dir"])
        let commonDir = git(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let linked = !gitDir.isEmpty && !commonDir.isEmpty && gitDir != commonDir
        let package = cwd.appendingPathComponent("package.json")
        let packageName = (try? Data(contentsOf: package)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["name"] as? String
        let packageLabel = label(packageName?.split(separator: "/").last.map(String.init) ?? "")
        let root = linked ? URL(fileURLWithPath: commonDir).deletingLastPathComponent().lastPathComponent : URL(fileURLWithPath: gitRoot).lastPathComponent
        let base = chosenName ?? (!packageLabel.isEmpty ? packageLabel : !gitRoot.isEmpty ? label(root) : label(cwd.lastPathComponent))
        guard !base.isEmpty else { throw CLIError("Cannot infer a dev name. Pass one explicitly.") }
        var name = base
        if linked {
            let branch = label(git(["symbolic-ref", "--quiet", "--short", "HEAD"]).split(separator: "/").last.map(String.init) ?? "")
            // Detached linked worktrees have no branch. Their commit provides a stable, usable label.
            let prefix = branch.isEmpty ? label(git(["rev-parse", "--short", "HEAD"])) : branch
            if !prefix.isEmpty { name = prefix + "." + base }
        }
        guard name.utf8.count <= 252 - domain.utf8.count else { throw CLIError("The dev name including its worktree prefix is too long.") }
        return name + "." + domain
    }

    private static func git(_ args: [String]) -> String {
        let r = runWithTimeout("/usr/bin/git", ["--no-optional-locks"] + args, timeout: 3, errorOutput: FileHandle.nullDevice)
        return r.code == 0 ? r.out : ""
    }
}
