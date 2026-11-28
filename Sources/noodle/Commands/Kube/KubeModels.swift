import Foundation
import NoodleCore

let kubeUsage = "usage: noodle kube play <file.yaml> [--down] | generate <container-or-pod>"
let kubeOwnerLabel = "dev.noodle.kube"

func kubeString(_ value: Any?) -> String { value.map { String(describing: $0) } ?? "" }
func kubeFields(_ object: [String: Any], _ allowed: [String], _ path: String) {
    for key in object.keys.sorted() where !allowed.contains(key) { err("warning: unsupported field \(path).\(key) ignored") }
}
func kubeName(_ value: Any?, _ path: String) throws -> String {
    guard let name = value as? String, !name.isEmpty,
          name.utf8.allSatisfy({ ($0 == 45 || $0 == 46 || (48...57).contains($0)) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }),
          name.first?.isLetter == true || name.first?.isNumber == true else {
        throw CLIError("\(path) must be a nonempty container or volume name")
    }
    return name
}

struct KubeWorkload {
    let name: String
    let owner: String
    var containers: [(name: String, body: [String: Any])]
    var volumes: [String: Bool] // true: ephemeral, false: persistent
}
