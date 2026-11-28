import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Testing
@testable import NoodleAPI

@Suite struct SpoolBudgetTests {
    /// Two parallel uploads share one free-disk allowance instead of each getting all of it.
    @Test func parallelSpoolsShareTheFreeDiskAllowance() throws {
        let dir = try scratchDir("spool"); defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = NIOLockedValueBox<Int64>(0)
        // Fake disk: 100 bytes free before any spool wrote, shrinking by what the spool files hold.
        let free: () -> Int64 = {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return 100 - files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        let a = try Spool(dir: dir, limit: 100, free: free, ledger: ledger)
        let b = try Spool(dir: dir, limit: 100, free: free, ledger: ledger)
        let chunk = { (n: Int) in ByteBuffer(bytes: [UInt8](repeating: 1, count: n)) }
        try a.append(chunk(60))
        #expect(throws: APIError.self) { try b.append(chunk(50)) }
        try b.append(chunk(40))
        #expect(ledger.withLockedValue { $0 } == 100)
        a.remove()
        #expect(ledger.withLockedValue { $0 } == 40)
        try b.append(chunk(50))
        b.remove(); b.remove()
        #expect(ledger.withLockedValue { $0 } == 0)
    }
}
