import Foundation
import Testing
@testable import NoodleVM

@Suite struct GuestKernelArgumentsTests {
    @Test func bothRolesBootTheAgentOnTheVirtioConsoleAndStopOnPanic() {
        for role in [VMRole.main, .workload] {
            let args = GuestKernelArguments.arguments(for: role)
            #expect(args.contains("rdinit=/init") && args.contains("console=hvc0") && args.contains("panic=1"))
            #expect(Set(args).count == args.count)
        }
    }

    @Test func tuningSwitchesStayOnBothRoles() {
        for role in [VMRole.main, .workload] {
            let line = GuestKernelArguments.commandLine(for: role)
            #expect(line.contains("swiotlb=noforce") && line.contains("rcupdate.rcu_expedited=1") && line.contains("quiet"))
        }
    }

    @Test func onlyTheWorkloadVMCarriesTheRoleMarker() {
        #expect(GuestKernelArguments.arguments(for: .workload).last == "noodle.role=workload")
        #expect(!GuestKernelArguments.commandLine(for: .main).contains("noodle.role"))
    }
}
