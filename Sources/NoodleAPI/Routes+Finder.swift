import Foundation
import NoodleEngine

extension Handlers {
    func finderRoutes(_ table: inout RouteTable) {
        let finder = FinderServer(engine: engine)
        table.get("noodle/finder") { _, writer in try await writer.json(await finder.status()) }
        table.post("noodle/finder") { request, writer in
            struct Input: Decodable { let mountpoint: String? }
            let input = try await request.decode(Input.self, limit: 16 << 10, invalid: "invalid Finder request", emptyAsObject: true)
            try await writer.json(try await finder.start(mountpoint: input.mountpoint))
        }
        table.delete("noodle/finder") { _, writer in try await writer.json(try await finder.stop()) }
    }
}
