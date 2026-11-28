import Foundation
import IOKit.pwr_mgt
import NoodleCore

struct IOKitAssertions: PowerAssertions {
    func create() -> UInt32? {
        var id = IOPMAssertionID(0)
        let r = IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            AwakeGuard.reason as CFString, &id)
        return r == kIOReturnSuccess ? id : nil
    }
    func release(_ id: UInt32) { IOPMAssertionRelease(id) }
}
