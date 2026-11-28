import Foundation
import Virtualization
import NoodleCore
import os

/// Hands each guest-initiated vsock connection to a handler as an owned, duplicated descriptor.
final class GuestListenerDelegate: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    var handler: (@Sendable (Int32) -> Void)?
    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection, from socketDevice: VZVirtioSocketDevice) -> Bool {
        guard let handler else { return false }
        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else { return false }
        handler(fd)
        return true
    }
}
