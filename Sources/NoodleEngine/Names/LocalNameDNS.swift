import Dispatch
import Foundation
import NoodleCore
import dnssd

/// Exact names installed in this Mac's resolver. Pending names are not yet usable.
public struct LocalNameDNSStatus: Codable, Sendable, Equatable {
    public var registered: [String]
    public var pending: [String]
    public var errors: [String: String]
}

/// One local-only connection, independent of the LAN. All C handles and callback contexts are
/// confined to `queue`, including removal and deallocation as required by DNSServiceSetDispatchQueue.
final class LocalNameDNS: @unchecked Sendable {
    private final class Record {
        let host: String
        weak var owner: LocalNameDNS?
        var refs: [DNSRecordRef] = []
        let requiredReplies: Int
        var replies = 0
        var ready: Bool { replies == requiredReplies }
        init(host: String, owner: LocalNameDNS, requiredReplies: Int) {
            self.host = host; self.owner = owner; self.requiredReplies = requiredReplies
        }
    }
    private struct Waiter {
        let host: String
        let continuation: CheckedContinuation<Void, any Error>
    }
    private let queue = DispatchQueue(label: "app.noodle.names.dns", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var connection: DNSServiceRef?
    private var records: [String: Record] = [:]
    private var errors: [String: String] = [:]
    private var waiters: [UUID: Waiter] = [:]
    private var stopped = false
    private var ipv6Enabled = false
    private let onChange: @Sendable () -> Void
    static let maximumRecords = 4096

    init(onChange: @escaping @Sendable () -> Void = {}) {
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit { onQueue { close() } }

    static func hostsToRegister(_ hosts: Set<String>) -> Set<String> {
        Set(hosts.filter { $0.hasSuffix("." + LocalNameDomain.brandedSuffix) && LocalNameDomain.isSupported($0) })
    }

    struct AddressRecord: Sendable, Equatable {
        let type: UInt16
        let bytes: [UInt8]
    }

    static func addressRecords(ipv6: Bool) -> [AddressRecord] {
        var records = [AddressRecord(type: UInt16(kDNSServiceType_A), bytes: [127, 0, 0, 1])]
        if ipv6 { records.append(AddressRecord(type: UInt16(kDNSServiceType_AAAA), bytes: Array(repeating: 0, count: 15) + [1])) }
        return records
    }

    /// Called once during router construction, after both actual listener pairs have bound.
    func enableIPv6() {
        onQueue {
            precondition(records.isEmpty && connection == nil)
            ipv6Enabled = true
        }
    }

    /// Hosts whose error came from a dead connection, not from the host itself: the next update registers them again.
    private var retryable: Set<String> = []

    private func onQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
        return queue.sync(execute: body)
    }

    var status: LocalNameDNSStatus {
        onQueue {
            LocalNameDNSStatus(registered: records.values.filter(\.ready).map(\.host).sorted(),
                               pending: records.values.filter { !$0.ready }.map(\.host).sorted(), errors: errors)
        }
    }

    func update(hosts: Set<String>) {
        onQueue {
            guard !stopped else { return }
            let wanted = Self.hostsToRegister(hosts)
            for host in retryable { errors[host] = nil }
            retryable = []
            for host in Set(records.keys).subtracting(wanted) { remove(host) }
            errors = errors.filter { wanted.contains($0.key) }
            let missing = wanted.subtracting(records.keys).subtracting(errors.keys).sorted()
            guard !missing.isEmpty else { return }
            if connection == nil {
                var ref: DNSServiceRef?
                let created = DNSServiceCreateConnection(&ref)
                guard created == kDNSServiceErr_NoError, let ref else {
                    for host in missing { errors[host] = Self.message(created) }
                    return
                }
                let scheduled = DNSServiceSetDispatchQueue(ref, queue)
                guard scheduled == kDNSServiceErr_NoError else {
                    DNSServiceRefDeallocate(ref)
                    for host in missing { errors[host] = Self.message(scheduled) }
                    return
                }
                connection = ref
            }
            for host in missing {
                guard records.count < Self.maximumRecords else {
                    errors[host] = "Local DNS registration limit reached."
                    continue
                }
                add(host)
            }
        }
    }

    /// This is a one-shot deadline for an API request, never a polling or maintenance timer.
    func waitUntilRegistered(_ host: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                if let error = errors[host] { continuation.resume(throwing: EngineError.unavailable(error)); return }
                guard let record = records[host], !stopped else {
                    continuation.resume(throwing: EngineError.unavailable("Local DNS route was removed.")); return
                }
                if record.ready { continuation.resume(); return }
                let id = UUID()
                waiters[id] = Waiter(host: host, continuation: continuation)
                queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, let waiter = self.waiters.removeValue(forKey: id) else { return }
                    waiter.continuation.resume(throwing: EngineError.unavailable("Local DNS registration for \(host) timed out."))
                }
            }
        }
    }

    func stop() { onQueue { stopped = true; close() } }

    private static func message(_ code: DNSServiceErrorType) -> String { "Local DNS registration failed (\(code))." }

    private func add(_ host: String) {
        guard let connection else {
            errors[host] = "Local DNS connection is unavailable."
            return
        }
        let addresses = Self.addressRecords(ipv6: ipv6Enabled)
        let record = Record(host: host, owner: self, requiredReplies: addresses.count)
        // Stored before registration; context stays alive until removal on this same serial queue.
        records[host] = record
        for address in addresses {
            var ref: DNSRecordRef?
            let result = address.bytes.withUnsafeBytes { bytes in
                DNSServiceRegisterRecord(connection, &ref, DNSServiceFlags(kDNSServiceFlagsUnique),
                                         UInt32(kDNSServiceInterfaceIndexLocalOnly), host + ".", address.type,
                                         UInt16(kDNSServiceClass_IN), UInt16(bytes.count), bytes.baseAddress, 0,
                                         { _, _, _, error, context in
                                             guard let context else { return }
                                             let record = Unmanaged<Record>.fromOpaque(context).takeUnretainedValue()
                                             record.owner?.completed(record, error: error)
                                         }, Unmanaged.passUnretained(record).toOpaque())
            }
            guard result == kDNSServiceErr_NoError, let ref else {
                errors[host] = Self.message(result)
                remove(host)
                return
            }
            record.refs.append(ref)
        }
    }

    private func completed(_ record: Record, error: DNSServiceErrorType) {
        guard records[record.host] === record else { return }
        if error == kDNSServiceErr_NoError {
            record.replies += 1
            if record.ready { finishWaiters(record.host, error: nil) }
        } else if error == kDNSServiceErr_ServiceNotRunning || error == kDNSServiceErr_DefunctConnection {
            let hosts = Array(records.keys)
            close()
            for host in hosts { errors[host] = Self.message(error) }
            retryable.formUnion(hosts) // mDNSResponder may be back by the next update
        } else {
            errors[record.host] = Self.message(error)
            remove(record.host)
        }
        onChange()
    }

    private func finishWaiters(_ host: String, error: String?) {
        for (id, waiter) in waiters where waiter.host == host {
            waiters[id] = nil
            if let error { waiter.continuation.resume(throwing: EngineError.unavailable(error)) }
            else { waiter.continuation.resume() }
        }
    }

    private func remove(_ host: String) {
        guard let record = records.removeValue(forKey: host) else { return }
        if let connection {
            for ref in record.refs {
                let result = DNSServiceRemoveRecord(connection, ref, 0)
                if result != kDNSServiceErr_NoError {
                    // A failed removal cannot leave a C callback holding a released context.
                    // Tear down the shared connection before releasing any remaining record contexts.
                    let remaining = Array(records.keys)
                    close()
                    for host in remaining { errors[host] = Self.message(result) }
                    break
                }
            }
        }
        finishWaiters(host, error: errors[host] ?? "Local DNS route was removed.")
        if records.isEmpty, let connection {
            DNSServiceRefDeallocate(connection)
            self.connection = nil
        }
    }

    private func close() {
        // Deallocation invalidates all records and prevents further callbacks before contexts are released.
        if let connection { DNSServiceRefDeallocate(connection); self.connection = nil }
        let hosts = Array(records.keys)
        records.removeAll()
        for host in hosts { finishWaiters(host, error: "Local DNS connection closed.") }
    }
}
