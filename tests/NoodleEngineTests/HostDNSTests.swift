import Foundation
import Testing
@testable import NoodleEngine

@Suite struct HostDNSTests {
    /// RFC 1035 header fields followed by the example.com A/IN question.
    private let query: Data = {
        var packet = Data()
        for field in [UInt16(0x6e29), 0x0100, 1, 0, 0, 0] {
            packet.append(UInt8(field >> 8))
            packet.append(UInt8(field & 0xff))
        }
        for part in "example.com".split(separator: ".") {
            packet.append(UInt8(part.utf8.count))
            packet.append(contentsOf: part.utf8)
        }
        packet.append(contentsOf: [0, 0, 1, 0, 1])
        return packet
    }()

    @Test func parsesTheQuestion() throws {
        let q = try #require(HostDNS.parseQuestion(query))
        #expect(q.name == "example.com")
        #expect(q.type == 1)
        #expect(q.cls == 1)
        #expect(q.wire.count == 17)
    }

    @Test func refusesTruncatedQueries() {
        #expect(HostDNS.parseQuestion(query.prefix(20)) == nil)
        #expect(HostDNS.parseQuestion(Data()) == nil)
    }

    @Test func responseEchoesIdAndQuestionAndCarriesRecords() throws {
        let q = try #require(HostDNS.parseQuestion(query))
        let address: [UInt8] = [192, 0, 2, 61]
        let record = HostDNS.Record(name: "example.com.", type: 1, cls: 1, ttl: 60, data: Data(address))
        let response = [UInt8](HostDNS.buildResponse(query: query, question: q, rcode: 0, records: [record]))
        #expect(Array(response[12..<29]) == Array(query.dropFirst(12)))
        #expect(Array(response.suffix(address.count)) == address)
        #expect(Array(response[0..<2]) == [0x6e, 0x29])
        #expect(Array(response[6..<8]) == [0, 1])
        #expect(response[3] & 0x0f == 0)
        #expect(response[2] & 0x80 != 0)
    }

    @Test func noSuchNameIsNXDOMAIN() throws {
        let q = try #require(HostDNS.parseQuestion(query))
        let bytes = [UInt8](HostDNS.buildResponse(query: query, question: q, rcode: 3, records: []))
        #expect(bytes[3] & 0x0f == 3)
    }
}
