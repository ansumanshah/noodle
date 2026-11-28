import Foundation
import NoodleCore
import Testing
@testable import NoodleApp

@Suite struct LinuxMachineCommandTests {
    private let machine = LinuxMachine(name: "dev", state: "running", distro: "alpine", image: "alpine:3.22",
                                       cpus: 1, memoryMiB: 512, diskGiB: 5)

    @Test func defaultHomeKeepsThePlainCommand() {
        let root = NoodlePaths.resolve(environment: [:]).root
        #expect(machine.shellCommand(root: root) == "noodle machine shell dev")
    }

    @Test func customHomeIsOneShellQuotedAssignment() throws {
        let root = URL(fileURLWithPath: "/tmp/Noodle's store $HOME `whoami`", isDirectory: true)
        let command = machine.shellCommand(root: root)
        #expect(command.hasPrefix("NOODLE_HOME='"))
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "noodle() { printf '%s\\n' \"$NOODLE_HOME\" \"$@\"; }; " + command]
        process.standardOutput = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(text == root.path + "\nmachine\nshell\ndev\n")
    }
}
