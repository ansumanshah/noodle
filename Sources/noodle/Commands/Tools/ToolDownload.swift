import Foundation
import NoodleCore

/// `handleSignals: false` is for callers that own the process's signals (the runners helper) and cancel `child` themselves.
func downloadTool(_ arguments: [String], child: ToolDownloadProcess = ToolDownloadProcess(), handleSignals: Bool = true) throws -> ToolDownloadProcess.Result {
    guard handleSignals else { return try child.run(executable: "/usr/bin/curl", arguments: arguments) }
    let signals = [SIGINT, SIGTERM, SIGHUP].map { number in
        let previous = signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { child.cancel(number) }
        source.resume()
        return (number, previous, source)
    }
    defer { for (number, previous, source) in signals { source.cancel(); signal(number, previous) } }
    return try child.run(executable: "/usr/bin/curl", arguments: arguments)
}
