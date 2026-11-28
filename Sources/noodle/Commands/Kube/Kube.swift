import Foundation
import NoodleCore

func cmdKube(_ args: [String]) {
    do {
        if args.count == 2, args[0] == "generate", !args[1].hasPrefix("-") {
            try kubeGenerate(args[1]); return
        }
        guard args.first == "play" else { throw CLIError.usage(kubeUsage) }
        let rest = Array(args.dropFirst())
        let down = rest.contains("--down")
        let files = rest.filter { $0 != "--down" }
        guard files.count == 1, rest.count == (down ? 2 : 1), !files[0].hasPrefix("-") else { throw CLIError.usage(kubeUsage) }
        let documents = try KubeYAML.parse(String(contentsOfFile: files[0], encoding: .utf8))
        let plans = try kubePlan(documents)
        let engine = EngineEndpoint(name: "noodled", socketPath: socketPath)
        if down {
            try kubeDown(plans, engine: engine)
        } else { try kubePlay(plans, engine: engine) }
    } catch { die(error, prefix: "kube: ") }
}
