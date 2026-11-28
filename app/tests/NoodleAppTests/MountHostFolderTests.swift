import Foundation
import Testing
@testable import NoodleApp

struct MountHostFolderTests {
    private func mount(_ json: String) throws -> ContainerDetails.Mount {
        try JSONDecoder().decode(ContainerDetails.Mount.self, from: Data(json.utf8))
    }

    @Test func bindMountOpensItsHostPath() throws {
        let m = try mount(#"{"Type":"bind","Source":"/Users/me/code","Destination":"/app"}"#)
        #expect(m.hostFolder?.path == "/Users/me/code")
    }

    @Test func namedVolumeHasNoHostFolder() throws {
        let m = try mount(#"{"Type":"volume","Name":"data","Source":"/var/lib/noodle/volumes/data","Destination":"/data"}"#)
        #expect(m.hostFolder == nil)
    }
}
