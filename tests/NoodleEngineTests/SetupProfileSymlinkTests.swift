import Foundation
import Testing
@testable import noodle

@Suite struct SetupProfileSymlinkTests {
    /// `setup --path` writes through a symlinked profile (dotfile managers) and keeps its mode.
    @Test func pathBlockWritesThroughSymlinkedProfile() throws {
        let home = try scratchDir("setup-home"); defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let real = home.appendingPathComponent("dotfiles-zshrc")
        try "alias ll=ls\n".write(to: real, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: real.path)
        let profile = home.appendingPathComponent(".zshrc")
        try fm.createSymbolicLink(at: profile, withDestinationURL: real)
        let block = "\n# >>> Noodle PATH >>>\nexport PATH=\"$HOME/.local/bin:$PATH\"\n# <<< Noodle PATH <<<\n"

        #expect(try setupAppendPathBlock(block, to: profile))
        #expect(try !setupAppendPathBlock(block, to: profile))
        #expect(try fm.destinationOfSymbolicLink(atPath: profile.path) == real.path)
        #expect(try String(contentsOf: real, encoding: .utf8) == "alias ll=ls\n" + block)
        #expect(try fm.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int == 0o640)
    }
}
