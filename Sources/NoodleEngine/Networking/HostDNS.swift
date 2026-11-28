import Foundation
import NoodleCore
import dnssd

/// Answers DNS queries the VM's resolver could not, with the Mac's system resolver. Only runs
/// when a query needs it. Each lookup blocks one thread of its own queue, so at most `maxLookups`
/// run at once and the rest get no answer.
enum HostDNS {
    static let maxLookups = 8
    private static let queue = DispatchQueue(label: "noodle.hostdns", attributes: .concurrent)
    private static let slots = DispatchSemaphore(value: maxLookups)

    struct Question: Equatable {
        var name: String
        var type: UInt16
        var cls: UInt16
        /// The question section, as sent.
        var wire: Data
    }

    struct Record {
        var name: String
        var type: UInt16
        var cls: UInt16
        var ttl: UInt32
        var data: Data
    }

    static func reply(to query: Data, id: Int64, through guest: GuestClient) async {
        let answer = await answer(query: query) ?? Data()
        _ = try? await guest.call(GuestOp.dnsAnswer, ["query": .int(id), "answer": .string(answer.base64EncodedString())])
    }

    static func answer(query: Data) async -> Data? {
        guard let question = parseQuestion(query), takeSlot() else { return nil }
        return await withCheckedContinuation { cont in
            queue.async {
                defer { slots.signal() }
                let (rcode, records) = lookup(question)
                cont.resume(returning: buildResponse(query: query, question: question, rcode: rcode, records: records))
            }
        }
    }

    private static func takeSlot() -> Bool { slots.wait(timeout: .now()) == .success }

    // MARK: DNS messages

    static func parseQuestion(_ query: Data) -> Question? {
        let bytes = [UInt8](query)
        guard bytes.count >= 17, bytes[4] == 0, bytes[5] == 1 else { return nil }
        var i = 12
        var labels: [String] = []
        while true {
            guard i < bytes.count else { return nil }
            let len = Int(bytes[i])
            i += 1
            if len == 0 { break }
            guard len < 64, i + len <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[i..<(i + len)], as: UTF8.self))
            i += len
        }
        guard i + 4 <= bytes.count else { return nil }
        let type = UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
        let cls = UInt16(bytes[i + 2]) << 8 | UInt16(bytes[i + 3])
        return Question(name: labels.joined(separator: "."), type: type, cls: cls, wire: Data(bytes[12..<(i + 4)]))
    }

    static func buildResponse(query: Data, question: Question, rcode: UInt8, records: [Record]) -> Data {
        let head = [UInt8](query.prefix(2))
        var out = Data(head)
        out.append(contentsOf: [0x81, 0x80 | (rcode & 0x0f), 0, 1])
        appendU16(&out, UInt16(records.count))
        out.append(contentsOf: [0, 0, 0, 0])
        out.append(question.wire)
        for r in records {
            encodeName(r.name, into: &out)
            appendU16(&out, r.type)
            appendU16(&out, r.cls)
            for shift in [24, 16, 8, 0] { out.append(UInt8((r.ttl >> UInt32(shift)) & 0xff)) }
            appendU16(&out, UInt16(r.data.count))
            out.append(r.data)
        }
        return out
    }

    private static func appendU16(_ out: inout Data, _ v: UInt16) {
        out.append(UInt8(v >> 8))
        out.append(UInt8(v & 0xff))
    }

    private static func encodeName(_ name: String, into out: inout Data) {
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8.prefix(63))
            out.append(UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(0)
    }

    // MARK: the system resolver

    private final class Collector {
        var records: [Record] = []
        var error: DNSServiceErrorType = DNSServiceErrorType(kDNSServiceErr_NoError)
        var finished = false
        let wanted: UInt16
        init(wanted: UInt16) { self.wanted = wanted }
    }

    /// Blocks up to 2.5 s. Returns a DNS rcode and the records found.
    private static func lookup(_ question: Question) -> (UInt8, [Record]) {
        let collector = Collector(wanted: question.type)
        var ref: DNSServiceRef?
        let flags = DNSServiceFlags(kDNSServiceFlagsReturnIntermediates)
        let started = DNSServiceQueryRecord(&ref, flags, 0, question.name, question.type, question.cls, { _, flags, _, error, name, type, cls, len, data, ttl, ctx in
            guard let ctx else { return }
            let c = Unmanaged<Collector>.fromOpaque(ctx).takeUnretainedValue()
            if error != kDNSServiceErr_NoError {
                c.error = error
                c.finished = true
                return
            }
            if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let name, let data {
                let rdata = Data(bytes: data, count: Int(len))
                c.records.append(Record(name: String(cString: name), type: type, cls: cls, ttl: ttl, data: rdata))
            }
            // A CNAME alone is not the answer yet.
            if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0, c.records.contains(where: { $0.type == c.wanted }) {
                c.finished = true
            }
        }, Unmanaged.passUnretained(collector).toOpaque())
        guard started == kDNSServiceErr_NoError, let ref else { return (2, []) }
        defer { DNSServiceRefDeallocate(ref) }

        let deadline = DispatchTime.now() + 2.5
        let fd = DNSServiceRefSockFD(ref)
        while !collector.finished {
            let left = Int64(deadline.uptimeNanoseconds) - Int64(DispatchTime.now().uptimeNanoseconds)
            if left <= 0 { break }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32(left / 1_000_000) + 1)
            if ready < 0, errno == EINTR { continue }
            if ready <= 0 { break }
            if DNSServiceProcessResult(ref) != kDNSServiceErr_NoError { break }
        }
        return outcome(error: collector.error, records: collector.records, finished: collector.finished)
    }

    static func outcome(error: DNSServiceErrorType, records: [Record], finished: Bool) -> (UInt8, [Record]) {
        switch Int(error) {
        case Int(kDNSServiceErr_NoError):
            return finished || !records.isEmpty ? (0, records) : (2, [])
        case Int(kDNSServiceErr_NoSuchName):
            return (3, [])
        case Int(kDNSServiceErr_NoSuchRecord):
            return (0, records)
        default:
            return (2, [])
        }
    }
}
