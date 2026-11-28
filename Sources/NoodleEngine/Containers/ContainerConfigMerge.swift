import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    static func mergeEnv(_ base: [String], _ over: [String]) -> [String] {
        var out = base
        for e in over {
            let key = e.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? e
            if let i = out.firstIndex(where: { $0 == key || $0.hasPrefix(key + "=") }) { out[i] = e } else { out.append(e) }
        }
        return out
    }

    func primaryNetworkName(_ mode: String) throws -> String {
        switch mode {
        case "", "default", "bridge": return "bridge"
        case "host", "none": return mode
        default:
            if mode.hasPrefix("container:") { return mode }
            return networks[try networkID(mode)]!.name
        }
    }
}
