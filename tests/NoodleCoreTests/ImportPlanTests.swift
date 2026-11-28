import Foundation
import Testing
@testable import NoodleCore

/// Fake engine documents stand in for OrbStack and Docker Desktop; nothing here talks to a real engine.
@Suite struct ImportPlanTests {
    @Test func digestPinnedImagesAreReferencedByDigest() {
        let digest = "alpine@sha256:" + String(repeating: "a", count: 64)
        #expect(ImportPlan.imageRefs(tags: ["alpine:3"], digests: [digest]) == ["alpine:3"])
        #expect(ImportPlan.imageRefs(tags: ["<none>:<none>"], digests: [digest]) == [digest])
        #expect(ImportPlan.imageRefs(tags: [], digests: ["<none>@<none>"]).isEmpty)
        #expect(ImportPlan.imageRefs(tags: [], digests: []).isEmpty)
    }

    @Test func digestOnlyImageCopiesOnceByID() {
        var target = Set<String>()
        var copies = 0
        for _ in 1...2 {
            if case .copy(let names) = ImportPlan.untaggedImageAction(id: "sha256:abc", targetHas: { target.contains($0) }) {
                #expect(names == ["sha256:abc"])
                copies += 1; target.insert(names[0])
            }
        }
        #expect(copies == 1)
    }

    @Test func volumesInUseCoverMountsBindsAndNeverStarted() {
        let running: ImportPlan.JSON = ["Mounts": [["Type": "volume", "Name": "data"], ["Type": "bind", "Source": "/x"]]]
        let created: ImportPlan.JSON = ["Mounts": [], "HostConfig": ["Binds": ["cache:/c:ro", "/host:/h"],
                                                                  "Mounts": [["Type": "volume", "Source": "logs", "Target": "/l"]]]]
        #expect(ImportPlan.volumesInUse(containerInspects: [running, created]) == ["data", "cache", "logs"])
        #expect(ImportPlan.volumesInUse(containerInspects: []).isEmpty)
    }

    @Test func containersSharingANetworkKeepIt() {
        let nets: ImportPlan.JSON = ["appnet": ["Aliases": ["web", "abc123"]]]
        let a = ImportPlan.network(hostConfig: ["NetworkMode": "appnet"], networks: nets)
        let b = ImportPlan.network(hostConfig: ["NetworkMode": "appnet"], networks: ["appnet": ["Aliases": ["db"]]])
        #expect(a?.name == "appnet" && a?.aliases == ["web", "abc123"])
        #expect(b?.name == "appnet" && b?.aliases == ["db"])
        #expect(ImportPlan.networksToCreate(wanted: [a!.name, b!.name, "other"], existing: []) == ["appnet", "other"])
        #expect(ImportPlan.networksToCreate(wanted: ["appnet"], existing: ["appnet"]).isEmpty)
        for mode in ["default", "bridge", "host", "none", "container:abc"] {
            #expect(ImportPlan.network(hostConfig: ["NetworkMode": mode], networks: nets) == nil)
        }
    }

    @Test func sourceNotRunningSaysSo() {
        let none = ImportPlan.sourceNotRunning(source: "orbstack", socketPath: "/s/docker.sock", socketExists: false)
        #expect(none.hasPrefix("OrbStack is not running") && none.contains("no socket at /s/docker.sock"))
        let stale = ImportPlan.sourceNotRunning(source: "desktop-linux", socketPath: "/s/d.sock", socketExists: true)
        #expect(stale.hasPrefix("Docker Desktop is not running") && stale.contains("does not answer"))
    }
}
