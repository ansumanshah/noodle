import Foundation

/// Process exit codes, one meaning each. Documented in the CLI reference.
enum ExitCode {
    /// The operation ran and failed, was declined, or timed out.
    static let failure: Int32 = 1
    /// Bad arguments, an unknown command, or a confirmation needed with no terminal and no --yes.
    static let usage: Int32 = 2
    /// The Noodle engine is not running or cannot be reached.
    static let engineDown: Int32 = 3
}

/// Usage error: message on stderr, exit 2.
func usageDie(_ s: String) -> Never { die(s, code: ExitCode.usage) }

/// Engine not running or unreachable: message on stderr, exit 3.
func engineDownDie(_ s: String = "cannot reach the Noodle engine (is it running? try `noodle start`)") -> Never {
    die(s, code: ExitCode.engineDown)
}

/// Errors that know which exit code they end the process with. Anything else exits 1.
protocol ExitCoded { var exitCode: Int32 { get } }

func exitCode(for error: Error) -> Int32 { (error as? ExitCoded)?.exitCode ?? ExitCode.failure }

/// Print a failure on stderr and exit with the code the error carries.
func die(_ error: Error, prefix: String = "") -> Never {
    die(prefix + String(describing: error), code: exitCode(for: error))
}

/// `--yes` answers a confirmation; `-y`, `-f` and `--force` are kept as aliases.
let yesFlags: Set<String> = ["--yes", "-y", "-f", "--force"]
func hasYes(_ args: [String]) -> Bool { args.contains { yesFlags.contains($0) } }

/// The CLI's one error type: a message for stderr and the exit code it ends the process with.
struct CLIError: Error, CustomStringConvertible, LocalizedError, ExitCoded {
    let description: String
    let exitCode: Int32
    var message: String { description }
    var errorDescription: String? { description }
    init(_ description: String, exitCode: Int32 = ExitCode.failure) { self.description = description; self.exitCode = exitCode }
    static func usage(_ message: String) -> CLIError { CLIError(message, exitCode: ExitCode.usage) }
    static func engineDown(_ message: String) -> CLIError { CLIError(message, exitCode: ExitCode.engineDown) }
}
