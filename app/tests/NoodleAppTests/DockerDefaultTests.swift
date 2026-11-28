import NoodleCore
import SwiftUI
import Testing
@testable import NoodleApp

@MainActor
struct DockerDefaultTests {
    private let desktop = SetupEngine(name: "desktop-linux", socket: "/tmp/other.sock", reachable: true, inUse: true,
                                      inventory: ImportInventory(images: 2, volumes: 1, containers: 0))

    @Test func planNamesTheEngineTheUndoAndWhatCanBeCopied() {
        let plan = DockerDefaultPlan(currentContext: "desktop-linux", contextMissing: false, override: nil, source: desktop)
        #expect(plan.currentName == "Docker Desktop")
        #expect(plan.undoCommand == "docker context use desktop-linux")
        #expect(plan.copyKinds == [.images, .volumes])
        #expect(plan.copyDetail == "2 tagged images and 1 volume")
    }

    @Test func planOffersNoCopyWithoutASourceOrItems() {
        let none = DockerDefaultPlan(currentContext: "default", contextMissing: true, override: "DOCKER_HOST", source: nil)
        #expect(none.copyDetail == nil && none.copyKinds.isEmpty)
        let empty = SetupEngine(name: "orbstack", socket: "/tmp/o.sock", reachable: true, inUse: true, inventory: ImportInventory())
        #expect(DockerDefaultPlan(currentContext: "orbstack", contextMissing: false, override: nil, source: empty).copyDetail == nil)
        let all = SetupEngine(name: "colima", socket: "/tmp/c.sock", reachable: true, inUse: true,
                              inventory: ImportInventory(images: 1, volumes: 3, containers: 2))
        #expect(DockerDefaultPlan(currentContext: "colima", contextMissing: false, override: nil, source: all).copyDetail
                == "1 tagged image, 3 volumes and 2 stopped containers")
    }

    @Test func sheetShowsWhatChangesStaysAndHowToUndo() async {
        let plan = DockerDefaultPlan(currentContext: "desktop-linux", contextMissing: true, override: "DOCKER_HOST", source: desktop)
        let r = await RenderHarness.render(DockerDefaultSheet(env: RenderHarness.env, preview: plan), name: "docker-default-sheet",
                                           size: CGSize(width: 500, height: 520))
        for needle in ["Use Noodle for docker?", "Docker Desktop", "Changes", "Stays", "Undo", "DOCKER_HOST",
                       "Also copy from Docker Desktop", "2 tagged images and 1 volume", "Add Context Only", "Use Noodle"] {
            #expect(r.contains(needle), "sheet is missing \"\(needle)\". Saw: \(r.labels.prefix(40))")
        }
    }

    @Test func containersNoteNamesTheOtherEngine() async {
        // The note is one row inside a page, so give it a page-sized column to sit at the top of.
        let column = VStack(spacing: 0) { DockerElsewhereNote(target: "desktop-linux", choose: {}, dismiss: {}); Spacer() }
            .frame(width: 760, height: 160)
        let r = await RenderHarness.render(column, name: "docker-elsewhere-note", size: CGSize(width: 760, height: 160))
        #expect(r.contains("Docker Desktop") && r.contains("Use Noodle for docker"))
    }
}
