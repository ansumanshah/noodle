import Foundation
import NoodleCore

// MARK: - Mac loopback relay

extension Engine {
    /// Register the vsock 1034 listener on the main VM, once at daemon start. Off when `host_loopback` is false.
    /// The workload VM never gets it: `VMController.setGuestListener` ignores non-main roles as well.
    func startHostLoopback() async {
        guard settings.hostLoopback else { return }
        let relay = HostLoopbackRelay(paths: paths)
        hostLoopbackRelay = relay
        await main.vm.setGuestListener(port: HostLoopback.vsockPort) { fd in relay.serve(guestFD: fd) }
    }

    /// Ask a freshly booted main VM to install its redirect. Best effort: a failure leaves today's NAT-only reach.
    func enableHostLoopback(in rt: GuestRuntime) async {
        guard rt === main, settings.hostLoopback else { return }
        do { _ = try await rt.guest.call(HostLoopback.guestOp, [:]) }
        catch { log.error("Mac loopback relay not started in the guest: \(String(describing: error), privacy: .public)") }
    }
}
