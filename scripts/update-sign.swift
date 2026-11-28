// Release-key tool for app updates. Run with `swift scripts/update-sign.swift <command>`.
//   keygen <key-file>                        new Ed25519 key; private half to <key-file> (0600), public half printed
//   public <key-file>                        print the public half (the NoodleUpdatePublicKey value)
//   feed <zip> <key-file> <version> <build> <arch> <url> [minimumSystem]   print the signed appcast.json
// The signed message must match UpdateFeed.signedMessage in Sources/NoodleCore/Update/UpdateFeed.swift.
import Foundation
import CryptoKit

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("update-sign: \(m)\n".utf8)); exit(1) }
func load(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("cannot read key \(path)") }
    return key
}

let a = Array(CommandLine.arguments.dropFirst())
switch a.first {
case "keygen" where a.count == 2:
    guard !FileManager.default.fileExists(atPath: a[1]) else { fail("\(a[1]) exists; refusing to overwrite") }
    let key = Curve25519.Signing.PrivateKey()
    let ok = FileManager.default.createFile(atPath: a[1], contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8), attributes: [.posixPermissions: 0o600])
    guard ok else { fail("cannot write \(a[1])") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public" where a.count == 2:
    print(load(a[1]).publicKey.rawRepresentation.base64EncodedString())
case "feed" where a.count == 7 || a.count == 8:
    guard let data = FileManager.default.contents(atPath: a[1]), let build = Int(a[4]) else { fail("bad zip or build") }
    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let minimum = a.count == 8 ? a[7] : "26.0"
    let message = Data("noodle-update-v1\n\(a[3])\n\(build)\n\(a[5])\n\(minimum)\n\(data.count)\n\(sha)\n".utf8)
    guard let sig = try? load(a[2]).signature(for: message).base64EncodedString() else { fail("signing failed") }
    let obj: [String: Any] = ["version": a[3], "build": build, "arch": a[5], "minimumSystem": minimum, "url": a[6],
                              "length": data.count, "sha256": sha, "signature": sig]
    guard let json = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { fail("feed encoding failed") }
    print(String(decoding: json, as: UTF8.self))
default: fail("usage: see the header of scripts/update-sign.swift")
}
