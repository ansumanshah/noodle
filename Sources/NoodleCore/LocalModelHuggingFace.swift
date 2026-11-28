import Foundation

/// The Hub contract used by local GGUF pulls. Parsing and selection do not perform network I/O.
public enum LocalModelHuggingFace {
    // A local single-file model cannot plausibly need more than 1 TiB. Bound untrusted
    // sizes before they reach download counters, filesystem offsets or memory estimates.
    private static let maximumFileBytes: UInt64 = 1 << 40

    public struct Failure: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    public struct Reference: Equatable, Sendable {
        public let organization: String
        public let repository: String
        public let quantization: String?

        public init(_ id: String) throws {
            let parts = id.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "hf.co" else {
                throw Failure("use hf.co/<org>/<repo>[:<quant>] for Hugging Face GGUF weights")
            }
            let tail = parts[2].split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(tail.count),
                  Self.validName(String(parts[1])), Self.validName(String(tail[0])) else {
                throw Failure("unsafe Hugging Face organization or repository name")
            }
            let quant = tail.count == 2 ? String(tail[1]) : nil
            if let quant {
                guard quant.utf8.count <= 32,
                      matches(quant, #"^[A-Za-z0-9]+(?:_[A-Za-z0-9]+)*$"#) else {
                    throw Failure("invalid GGUF quantization token")
                }
            }
            organization = String(parts[1])
            repository = String(tail[0])
            quantization = quant?.uppercased()
        }

        public var id: String {
            "hf.co/\(organization)/\(repository)" + (quantization.map { ":" + $0 } ?? "")
        }

        /// A separate namespace and a full digest avoid aliases with local import IDs and case-folding paths.
        public var storageKey: String { Digest.sha256Hex(Data(id.utf8)) }

        public var metadataURL: URL {
            URL(string: "https://huggingface.co/api/models/\(organization)/\(repository)?blobs=true")!
        }

        private static func validName(_ name: String) -> Bool {
            name.utf8.count <= 96 && !name.contains("..")
                && matches(name, #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#)
        }
    }

    /// Stored beside model.gguf in the same atomic directory installation.
    public struct Receipt: Codable, Equatable, Sendable {
        public let logicalID: String
        public let revision: String
        public let filename: String
        /// Digest spelling shared with the existing download verifier.
        public let sha256: String
        public let bytes: UInt64

        private enum CodingKeys: String, CodingKey { case logicalID, revision, filename, sha256, bytes }

        public init(logicalID: String, revision: String, filename: String, sha256: String, bytes: UInt64) throws {
            let reference = try Reference(logicalID)
            guard reference.id == logicalID, matches(revision, #"^[a-fA-F0-9]{40}$"#) else {
                throw Failure("Hugging Face metadata must include an immutable commit SHA")
            }
            guard validFilename(filename), filename.lowercased().hasSuffix(".gguf"),
                  !filename.lowercased().contains("mmproj"), !isDraftSidecar(filename), !isShard(filename) else {
                throw Failure("unsafe or unsupported GGUF filename in Hugging Face metadata")
            }
            if let quantization = reference.quantization, !hasQuantization(quantization, filename: filename) {
                throw Failure("GGUF filename does not match the receipt's quantization")
            }
            let normalizedHash = sha256.lowercased()
            guard normalizedHash.hasPrefix("sha256:"), Digest.isValid(normalizedHash), bytes >= 24 else {
                throw Failure("GGUF metadata must include a valid LFS SHA-256 and file size")
            }
            guard bytes <= maximumFileBytes else {
                throw Failure("GGUF file size exceeds the supported 1 TiB per-file limit")
            }
            self.logicalID = logicalID
            self.revision = revision.lowercased()
            self.filename = filename
            self.sha256 = normalizedHash
            self.bytes = bytes
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(logicalID: values.decode(String.self, forKey: .logicalID),
                          revision: values.decode(String.self, forKey: .revision),
                          filename: values.decode(String.self, forKey: .filename),
                          sha256: values.decode(String.self, forKey: .sha256),
                          bytes: values.decode(UInt64.self, forKey: .bytes))
        }

        public func downloadURL() throws -> URL {
            // Each component is escaped separately; separators cannot turn into query strings or fragments.
            let reference = try Reference(logicalID)
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let escaped = filename.split(separator: "/").map {
                String($0).addingPercentEncoding(withAllowedCharacters: allowed)!
            }.joined(separator: "/")
            return URL(string: "https://huggingface.co/\(reference.organization)/\(reference.repository)/resolve/\(revision)/\(escaped)")!
        }
    }

    private struct Metadata: Decodable {
        let sha: String
        let siblings: [Sibling]
    }

    private struct Sibling: Decodable {
        struct LFS: Decodable {
            let sha256: String?
            let size: UInt64?
        }
        let rfilename: String
        let size: UInt64?
        let lfs: LFS?
        var bytes: UInt64? { lfs?.size ?? size }
    }

    public static func resolve(_ data: Data, for reference: Reference) throws -> Receipt {
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        guard matches(metadata.sha, #"^[a-fA-F0-9]{40}$"#) else {
            throw Failure("Hugging Face metadata is missing an immutable commit SHA")
        }
        let ggufs = metadata.siblings.filter {
            $0.rfilename.lowercased().hasSuffix(".gguf") && !$0.rfilename.lowercased().contains("mmproj")
                && !isDraftSidecar($0.rfilename)
        }
        guard !ggufs.isEmpty else {
            throw Failure("this repository has no runnable GGUF weights (mmproj files and draft/MTP sidecars are skipped)")
        }
        guard ggufs.allSatisfy({ validFilename($0.rfilename) }) else {
            throw Failure("unsafe GGUF filename in Hugging Face metadata")
        }
        let preferred = reference.quantization ?? "Q4_K_M"
        let matching = ggufs.filter { hasQuantization(preferred, filename: $0.rfilename) }
        if reference.quantization != nil, matching.isEmpty {
            throw Failure("no GGUF file matches quantization \(preferred) exactly")
        }
        let candidates = matching.isEmpty ? ggufs : matching
        let singleFiles = candidates.filter { !isShard($0.rfilename) }
        guard !singleFiles.isEmpty else {
            throw Failure("split GGUF shards are not supported; choose a repository or quantization with a single GGUF file")
        }
        // Fail closed instead of silently changing quantization when the chosen weights lack metadata.
        let validated = try singleFiles.map { file -> Receipt in
            guard let hash = file.lfs?.sha256, matches(hash, #"^[a-fA-F0-9]{64}$"#),
                  let bytes = file.bytes else {
                throw Failure("GGUF \(file.rfilename) is missing a valid LFS SHA-256 or file size")
            }
            if let size = file.size, let lfsSize = file.lfs?.size, size != lfsSize {
                throw Failure("conflicting file sizes for GGUF \(file.rfilename)")
            }
            return try Receipt(logicalID: reference.id, revision: metadata.sha, filename: file.rfilename,
                               sha256: "sha256:" + hash, bytes: bytes)
        }
        return validated.sorted {
            $0.bytes == $1.bytes ? $0.filename < $1.filename : $0.bytes < $1.bytes
        }[0]
    }

    private static func hasQuantization(_ quantization: String, filename: String) -> Bool {
        let basename = String(filename.split(separator: "/").last ?? "")
        // Keep underscores inside quantization tokens: Q4_K cannot select Q4_K_M,
        // and K_M cannot select the suffix of Q4_K_M. A model_name_ prefix is allowed.
        let pattern = #"(?i)(?<![a-z0-9])(?:IQ[0-9]+|Q[0-9]+|TQ[0-9]+|BF16|F16|F32|FP16|FP32|MXFP[0-9]+|NVFP[0-9]+)(?:_[a-z0-9]+)*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.matches(in: basename, range: NSRange(basename.startIndex..., in: basename)).contains { match in
            guard let range = Range(match.range, in: basename) else { return false }
            return basename[range].uppercased() == quantization
        }
    }

    private static func isShard(_ filename: String) -> Bool {
        matches(filename, #"(?i)-[0-9]+-of-[0-9]+\.gguf$"#)
    }

    private static func isDraftSidecar(_ filename: String) -> Bool {
        let basename = String(filename.split(separator: "/").last ?? "")
        // Match draft sidecar conventions in the basename, not generic words or directories.
        return ["mtp-", "dflash-", "eagle3-", "dspark-"].contains { basename.contains($0) }
    }

    private static func validFilename(_ filename: String) -> Bool {
        guard filename.utf8.count <= 1_024, !filename.contains("\\"), !filename.contains("%"),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        return filename.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression) else { return false }
        return !pattern.hasPrefix("^") || range == value.startIndex..<value.endIndex
    }
}
