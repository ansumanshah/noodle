import Foundation

// MARK: - Captured subprocess

/// Runs `executable args`, merging stdout and stderr, and returns the exit status with the output.
/// Stdin is closed. Throws only when the process cannot launch.
public func runCapturing(_ executable: URL, _ args: [String], environment: [String: String]? = nil) throws -> (status: Int32, output: String) {
    let p = Process(), pipe = Pipe()
    p.executableURL = executable; p.arguments = args
    if let environment { p.environment = environment }
    p.standardInput = FileHandle.nullDevice; p.standardOutput = pipe; p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
