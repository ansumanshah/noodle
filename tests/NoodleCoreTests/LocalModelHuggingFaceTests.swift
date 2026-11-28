import Foundation
import Testing
@testable import NoodleCore

@Suite struct LocalModelHuggingFaceTests {
    private let revision = String(repeating: "a", count: 40)
    private let hash = String(repeating: "b", count: 64)

    private func file(_ name: String, bytes: UInt64 = 100, hash: String? = nil) -> [String: Any] {
        ["rfilename": name, "size": bytes, "lfs": ["sha256": hash ?? self.hash, "size": bytes]]
    }

    private func metadata(_ files: [[String: Any]], revision: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["sha": revision ?? self.revision, "siblings": files])
    }

    private func resolve(_ files: [[String: Any]], id: String = "hf.co/Org/Repo") throws -> LocalModelHuggingFace.Receipt {
        try LocalModelHuggingFace.resolve(metadata(files), for: .init(id))
    }

    @Test func parsesLogicalIDAndRequestsBlobMetadata() throws {
        let reference = try LocalModelHuggingFace.Reference("hf.co/Org/Repo-GGUF:q4_k_m")
        #expect(reference.organization == "Org")
        #expect(reference.repository == "Repo-GGUF")
        #expect(reference.quantization == "Q4_K_M")
        #expect(reference.id == "hf.co/Org/Repo-GGUF:Q4_K_M")
        #expect(reference.metadataURL.absoluteString == "https://huggingface.co/api/models/Org/Repo-GGUF?blobs=true")
    }

    @Test(arguments: [
        "hf.co/../repo", "hf.co/org/..", "hf.co/org/../repo", "hf.co//repo", "hf.co/org/",
        "hf.co/org/repo/extra", "hf.co/org/repo:Q4:Q5", "hf.co/org/repo:",
        "hf.co/org/repo:Q4_K_M?download=true", "hf.co/org/repo@main", "hf.co/org/repo#fragment",
        "hf.co/org/repo?query", "hf.co/org/repo%2f..", "hf.co/org/repo\\x", "hf.co/org\n/repo",
        "hf.co/org/repo\n", "hf.co/org/repo:Q4\n", "hf.co/org/repo:ß", "https://hf.co/org/repo", "hf.co/órg/repo",
    ])
    func rejectsUnsafeReferences(_ id: String) {
        #expect(throws: LocalModelHuggingFace.Failure.self) { try LocalModelHuggingFace.Reference(id) }
    }

    @Test func storageKeysDoNotAliasImportsOrOtherLogicalIDs() throws {
        let reference = try LocalModelHuggingFace.Reference("hf.co/a/b:q4_k_m")
        let upper = try LocalModelHuggingFace.Reference("hf.co/a/b:Q4_K_M")
        let distinct = try LocalModelHuggingFace.Reference("hf.co/a-b/c")
        let other = try LocalModelHuggingFace.Reference("hf.co/a/b-c")
        #expect(reference.storageKey == upper.storageKey)
        #expect(reference.storageKey.count == 64)
        #expect(!reference.storageKey.contains("/") && !reference.storageKey.contains(":"))
        #expect(distinct.storageKey != other.storageKey)
        #expect(try LocalModelHuggingFace.Reference("hf.co/A/b").storageKey != LocalModelHuggingFace.Reference("hf.co/a/b").storageKey)
    }

    @Test func defaultPrefersQ4KMEvenWhenAnotherFileIsSmaller() throws {
        let receipt = try resolve([file("model.Q2_K.gguf", bytes: 50), file("model.Q4_K_M.gguf", bytes: 200)])
        #expect(receipt.filename == "model.Q4_K_M.gguf")
        #expect(receipt.bytes == 200)
        #expect(receipt.logicalID == "hf.co/Org/Repo")
        #expect(receipt.revision == revision && receipt.sha256 == "sha256:" + hash)
    }

    @Test func defaultFallsBackToSmallestWithStableFilenameTieBreak() throws {
        let receipt = try resolve([file("z.Q5_K_M.gguf", bytes: 100), file("a.Q5_K_M.gguf", bytes: 100),
                                   file("model.Q8_0.gguf", bytes: 200)])
        #expect(receipt.filename == "a.Q5_K_M.gguf")
    }

    @Test func explicitQuantIsCaseInsensitiveAndMatchesWholeToken() throws {
        let files = [file("model.Q4_K_M.gguf"), file("model.Q4_K_MX.gguf", bytes: 50),
                     file("model.Q4_K.gguf", bytes: 75), file("model.IQ4_K_M.gguf", bytes: 25)]
        let receipt = try resolve(files, id: "hf.co/Org/Repo:q4_k_m")
        #expect(receipt.filename == "model.Q4_K_M.gguf")
        #expect(receipt.logicalID == "hf.co/Org/Repo:Q4_K_M")
        #expect(try resolve([file("model_q4_k_m.GGUF")], id: "hf.co/Org/Repo:Q4_K_M").bytes == 100)
        #expect(throws: LocalModelHuggingFace.Failure.self) {
            try resolve([file("model.Q4_K_M.gguf")], id: "hf.co/Org/Repo:Q4_K")
        }
        #expect(throws: LocalModelHuggingFace.Failure.self) {
            try resolve([file("model.Q4_K_M.gguf")], id: "hf.co/Org/Repo:K_M")
        }
    }

    @Test func refusesMissingRequestedQuantInsteadOfSubstitutingWeights() {
        #expect(throws: LocalModelHuggingFace.Failure.self) {
            try resolve([file("model.Q8_0.gguf")], id: "hf.co/Org/Repo:Q5_K_M")
        }
    }

    @Test func skipsProjectionFilesAndOtherFormats() throws {
        let receipt = try resolve([file("mmproj-model.Q4_K_M.gguf", bytes: 24),
                                   file("model.safetensors", bytes: 24), file("model.Q8_0.gguf", bytes: 200)])
        #expect(receipt.filename == "model.Q8_0.gguf")
        #expect(throws: LocalModelHuggingFace.Failure.self) { try resolve([file("MMPROJ.gguf")]) }
        #expect(throws: LocalModelHuggingFace.Failure.self) { try resolve([file("model.safetensors")]) }
    }

    @Test(arguments: ["hf.co/Org/Repo", "hf.co/Org/Repo:BF16"])
    func skipsSmallerDraftAndMTPSidecarsBeforeQuantizationSelection(_ id: String) throws {
        let full = "Mellum2.1-12B-A2.5B-Thinking-BF16.gguf"
        let receipt = try resolve([
            file(full, bytes: 24_300_000_000),
            file("mtp-" + full, bytes: 1_770_000_000),
            file("dflash-model-BF16.gguf", bytes: 1_000_000_000),
            file("eagle3-model-Q4_K_M.gguf", bytes: 500_000_000),
            file("dspark-model-Q4_K_M.gguf", bytes: 400_000_000),
        ], id: id)
        #expect(receipt.filename == full)
        #expect(receipt.bytes == 24_300_000_000)
    }

    @Test func sidecarDoesNotSatisfyRequestedQuantization() throws {
        do {
            _ = try resolve([file("model.Q8_0.gguf"), file("mtp-model.Q4_K_M.gguf")],
                            id: "hf.co/Org/Repo:Q4_K_M")
            Issue.record("a sidecar satisfied the requested quantization")
        } catch let error as LocalModelHuggingFace.Failure {
            #expect(error.message.contains("no GGUF file matches quantization Q4_K_M"))
        }
    }

    @Test(arguments: ["mtp-model.BF16.gguf", "dflash-model.BF16.gguf", "eagle3-model.BF16.gguf",
                      "dspark-model.BF16.gguf", "nested/model-mtp-BF16.gguf"])
    func refusesSidecarOnlyRepositoriesAndReceipts(_ filename: String) throws {
        do {
            _ = try resolve([file(filename)])
            Issue.record("a sidecar was selected as runnable weights")
        } catch let error as LocalModelHuggingFace.Failure {
            #expect(error.message.contains("no runnable GGUF weights"))
            #expect(error.message.contains("draft/MTP sidecars are skipped"))
        }
        #expect(throws: LocalModelHuggingFace.Failure.self) {
            try LocalModelHuggingFace.Receipt(logicalID: "hf.co/Org/Repo", revision: revision,
                                            filename: filename, sha256: "sha256:" + hash, bytes: 100)
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "logicalID": "hf.co/Org/Repo", "revision": revision, "filename": filename,
            "sha256": "sha256:" + hash, "bytes": 100,
        ])
        #expect(throws: LocalModelHuggingFace.Failure.self) {
            try JSONDecoder().decode(LocalModelHuggingFace.Receipt.self, from: data)
        }
    }

    @Test(arguments: ["draft-model.BF16.gguf", "model-mtp.BF16.gguf", "model-dflash.BF16.gguf",
                      "model-eagle3.BF16.gguf", "model-dspark.BF16.gguf", "Mellum-with-MTP-BF16.gguf",
                      "mtp-/dflash-/eagle3-/dspark-/model.BF16.gguf"])
    func keepsFullModelNamesOutsidePinnedSidecarRules(_ filename: String) throws {
        #expect(try resolve([file(filename)], id: "hf.co/Org/Repo:BF16").filename == filename)
    }

    @Test func refusesSplitShardsWithAnActionableMessage() throws {
        do {
            _ = try resolve([file("model.Q4_K_M-00001-of-00002.gguf"), file("model.Q4_K_M-00002-of-00002.gguf")])
            Issue.record("split GGUF weights were selected")
        } catch let error as LocalModelHuggingFace.Failure {
            #expect(error.message.contains("split GGUF"))
            #expect(error.message.contains("single GGUF"))
        }
        let receipt = try resolve([file("model.Q4_K_M-00001-of-00002.gguf"), file("model.Q4_K_M.gguf", bytes: 200)])
        #expect(receipt.filename == "model.Q4_K_M.gguf")
    }

    @Test func explicitQuantRefusesShardsInsteadOfUsingAnotherQuant() {
        #expect(throws: LocalModelHuggingFace.Failure.self) {
            try resolve([file("model.Q4_K_M.gguf"), file("model.Q8_0-00001-of-00002.gguf")],
                        id: "hf.co/Org/Repo:Q8_0")
        }
    }

    @Test(arguments: ["../model.gguf", "/model.gguf", "folder/../model.gguf", "folder//model.gguf",
                      "./model.gguf", "folder\\model.gguf", "%2e%2e/model.gguf", "bad\nmodel.gguf"])
    func rejectsUnsafeRemoteFilenames(_ filename: String) {
        #expect(throws: LocalModelHuggingFace.Failure.self) { try resolve([file(filename)]) }
    }

    @Test func escapesNestedDownloadPathsAndPinsReturnedCommit() throws {
        let receipt = try resolve([file("sub folder/model #1?Q4_K_M.gguf")])
        #expect(try receipt.downloadURL().absoluteString == "https://huggingface.co/Org/Repo/resolve/\(revision)/sub%20folder/model%20%231%3FQ4_K_M.gguf")
        let url = try receipt.downloadURL()
        #expect(url.query == nil && url.fragment == nil)
    }

    @Test(arguments: ["", "main", "../main", String(repeating: "a", count: 39), String(repeating: "z", count: 40)])
    func refusesMissingOrMutableRevision(_ revision: String) throws {
        let data = try metadata([file("model.gguf")], revision: revision)
        #expect(throws: LocalModelHuggingFace.Failure.self) {
            try LocalModelHuggingFace.resolve(data, for: .init("hf.co/Org/Repo"))
        }
    }

    @Test(arguments: ["", String(repeating: "a", count: 63), String(repeating: "g", count: 64), "sha256:" + String(repeating: "a", count: 64), "../../escape"])
    func refusesInvalidLFSHashes(_ hash: String) {
        #expect(throws: LocalModelHuggingFace.Failure.self) { try resolve([file("model.gguf", hash: hash)]) }
    }

    @Test func requiresLFSHashRatherThanGitBlobID() throws {
        let missing: [String: Any] = ["rfilename": "model.gguf", "size": 100, "blobId": hash]
        #expect(throws: LocalModelHuggingFace.Failure.self) { try resolve([missing]) }
        let noHash: [String: Any] = ["rfilename": "model.gguf", "size": 100, "lfs": ["size": 100]]
        #expect(throws: LocalModelHuggingFace.Failure.self) { try resolve([noHash]) }
    }

    @Test func acceptsSiblingOrLFSSizeButRejectsConflicts() throws {
        let siblingSize: [String: Any] = ["rfilename": "model.gguf", "size": 101, "lfs": ["sha256": hash]]
        let lfsSize: [String: Any] = ["rfilename": "model.gguf", "lfs": ["sha256": hash, "size": 102]]
        #expect(try resolve([siblingSize]).bytes == 101)
        #expect(try resolve([lfsSize]).bytes == 102)
        let conflict: [String: Any] = ["rfilename": "model.gguf", "size": 101, "lfs": ["sha256": hash, "size": 102]]
        #expect(throws: LocalModelHuggingFace.Failure.self) { try resolve([conflict]) }
        #expect(throws: LocalModelHuggingFace.Failure.self) { try resolve([file("model.gguf", bytes: 0)]) }
        let missing: [String: Any] = ["rfilename": "model.gguf", "lfs": ["sha256": hash]]
        #expect(throws: LocalModelHuggingFace.Failure.self) { try resolve([missing]) }
    }

    @Test(arguments: [(UInt64(1) << 40) + 1, UInt64(Int64.max), UInt64.max - (1 << 30), UInt64.max])
    func rejectsUnrealisticMetadataAndReceiptSizes(_ bytes: UInt64) throws {
        // Literal integers preserve the hostile value exactly, including UInt64.max.
        let metadataJSON = """
        {"sha":"\(revision)","siblings":[{"rfilename":"model.gguf","size":\(bytes),"lfs":{"sha256":"\(hash)","size":\(bytes)}}]}
        """
        #expect(throws: LocalModelHuggingFace.Failure.self) {
            try LocalModelHuggingFace.resolve(Data(metadataJSON.utf8), for: .init("hf.co/Org/Repo"))
        }
        let receiptJSON = """
        {"logicalID":"hf.co/Org/Repo","revision":"\(revision)","filename":"model.gguf","sha256":"sha256:\(hash)","bytes":\(bytes)}
        """
        #expect(throws: LocalModelHuggingFace.Failure.self) {
            try JSONDecoder().decode(LocalModelHuggingFace.Receipt.self, from: Data(receiptJSON.utf8))
        }
    }

    @Test func acceptsFileSizeAtSanityLimit() throws {
        let bytes = UInt64(1) << 40
        #expect(try resolve([file("model.gguf", bytes: bytes)]).bytes == bytes)
    }

    @Test func receiptRoundTripRetainsProvenanceAndValidatesUntrustedJSON() throws {
        let receipt = try resolve([file("nested/model.Q4_K_M.gguf", hash: hash.uppercased())], id: "hf.co/Org/Repo:Q4_K_M")
        let data = try JSONEncoder().encode(receipt)
        #expect(try JSONDecoder().decode(LocalModelHuggingFace.Receipt.self, from: data) == receipt)
        #expect(receipt.sha256 == "sha256:" + hash)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["filename"] = "../outside.gguf"
        let unsafe = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: LocalModelHuggingFace.Failure.self) {
            try JSONDecoder().decode(LocalModelHuggingFace.Receipt.self, from: unsafe)
        }
    }

    @Test func receiptRejectsFilenameForAnotherQuantization() {
        #expect(throws: LocalModelHuggingFace.Failure.self) {
            try LocalModelHuggingFace.Receipt(logicalID: "hf.co/Org/Repo:Q8_0", revision: revision,
                                            filename: "model.Q4_K_M.gguf", sha256: "sha256:" + hash, bytes: 100)
        }
    }

    @Test func rejectsIncompleteMetadata() {
        for json in [#"{"siblings":[]}"#, #"{"sha":"main"}"#, #"{"sha":null,"siblings":[]}"#] {
            #expect(throws: (any Error).self) {
                try LocalModelHuggingFace.resolve(Data(json.utf8), for: .init("hf.co/Org/Repo"))
            }
        }
    }
}
