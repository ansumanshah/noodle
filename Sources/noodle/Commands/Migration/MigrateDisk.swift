import Foundation
import NoodleCore

func cmdMigrateDisk(_ args: [String]) {
    let dryRun = args == ["--dry-run"]
    guard args.isEmpty || dryRun else { usageDie("usage: noodle migrate-disk [--dry-run]") }
    guard let resources = paths.resourcesDirectory else { die("cannot locate Noodle's resources; reinstall Noodle") }
    do {
        let outcome = try DiskMigration.migrate(root: paths.root, tools: DiskMigration.Tools(resources: resources), dryRun: dryRun) { note($0) }
        switch outcome {
        case .alreadyJournaled:
            note("The data disk already has a journal. Nothing to do.")
        case .dryRun(let need, let free):
            note("Ready to migrate \(paths.dataDisk.path). Needs \(DiskMigration.mib(need)) MiB free, \(DiskMigration.mib(free)) MiB available. Nothing was changed.")
        case .migrated(let report):
            note("Migrated. Noodle will use the journaled disk at \(paths.dataDisk.path).")
            note("Your original disk is kept untouched at \(report.backup.path). Delete it yourself once you are satisfied; Noodle never will.")
            if report.repairedByFsck { note("Note: the old disk needed minor automatic repairs on the copy (it was not shut down cleanly).") }
        }
    } catch {
        err("noodle: migrate-disk failed: \(error)")
        exit(1)
    }
}
