import Foundation
import NoodleCore

extension ModelStore {
    private var huggingFaceDirectory: URL { weights.appendingPathComponent("huggingface", isDirectory: true) }

    func huggingFacePath(for reference: LocalModelHuggingFace.Reference) -> URL {
        huggingFaceDirectory.appendingPathComponent(reference.storageKey, isDirectory: true)
            .appendingPathComponent("model.gguf")
    }

    func huggingFaceReceipt(at bundle: URL, for reference: LocalModelHuggingFace.Reference? = nil) throws -> LocalModelHuggingFace.Receipt {
        let receiptFile = bundle.appendingPathComponent("receipt.json")
        let target = bundle.appendingPathComponent("model.gguf")
        let directoryInfo = try bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let receiptInfo = try receiptFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let targetInfo = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard directoryInfo.isDirectory == true, directoryInfo.isSymbolicLink != true,
              receiptInfo.isRegularFile == true, receiptInfo.isSymbolicLink != true,
              let receiptSize = receiptInfo.fileSize, (1...16_384).contains(receiptSize),
              targetInfo.isRegularFile == true, targetInfo.isSymbolicLink != true else {
            throw CLIError("invalid Hugging Face model installation")
        }
        let receipt = try JSONDecoder().decode(LocalModelHuggingFace.Receipt.self, from: Data(contentsOf: receiptFile))
        let storedReference = try LocalModelHuggingFace.Reference(receipt.logicalID)
        guard bundle.lastPathComponent == storedReference.storageKey,
              reference == nil || reference == storedReference,
              let size = targetInfo.fileSize, size >= 0, UInt64(size) == receipt.bytes else {
            throw CLIError("Hugging Face weights and receipt do not match; remove this installation before pulling again")
        }
        return receipt
    }

    func huggingFaceModels() -> [LocalModel] {
        let bundles = (try? FileManager.default.contentsOfDirectory(at: huggingFaceDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        return bundles.compactMap { bundle in
            guard let receipt = try? huggingFaceReceipt(at: bundle) else { return nil }
            return LocalModel(id: receipt.logicalID, name: receipt.logicalID, bytes: receipt.bytes,
                              installed: true, downloadable: true)
        }
    }

    func pullHuggingFace(_ reference: LocalModelHuggingFace.Reference,
                         report: (@Sendable (LocalModelPullProgress) -> Void)?) throws {
        let target = huggingFacePath(for: reference)
        // Re-pulls verify the installed immutable receipt, without following a moving Hub branch.
        if FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) {
            let receipt = try huggingFaceReceipt(at: target.deletingLastPathComponent(), for: reference)
            report?(.init(phase: .verifying, receivedBytes: receipt.bytes, totalBytes: receipt.bytes))
            guard try Digest.sha256(file: target) == receipt.sha256 else {
                throw CLIError("installed Hugging Face weights differ from their receipt. Remove \(reference.id) before pulling again.")
            }
            try checkGGUF(target)
            report?(.init(phase: .installed, receivedBytes: receipt.bytes, totalBytes: receipt.bytes))
            return
        }

        let result = try withHuggingFaceAuth(for: reference.metadataURL.absoluteString) { auth in
            run("/usr/bin/curl", auth + [
                "--disable", "--fail", "--silent", "--show-error", "--location",
                "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "20",
                "--max-time", "60", "--max-filesize", "8388608", reference.metadataURL.absoluteString,
            ])
        }
        guard result.code == 0 else {
            throw CLIError("could not fetch Hugging Face model metadata. \(result.out)")
        }
        let receipt = try LocalModelHuggingFace.resolve(Data(result.out.utf8), for: reference)
        err("Downloading \(reference.id) · \(receipt.filename) (\(receipt.bytes) bytes)")
        try stage { staging in
            let downloaded = staging.appendingPathComponent("model.gguf")
            try download(receipt.downloadURL().absoluteString, to: downloaded, sha256: receipt.sha256,
                         totalBytes: receipt.bytes, report: report)
            let size = try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size.map({ $0 >= 0 && UInt64($0) == receipt.bytes }) == true else {
                throw CLIError("download size differs from Hugging Face metadata")
            }
            try install(downloaded, at: target, receipt: receipt)
        }
        report?(.init(phase: .installed, receivedBytes: receipt.bytes, totalBytes: receipt.bytes))
    }
}
