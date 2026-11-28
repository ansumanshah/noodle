import Foundation
import Testing
@testable import NoodleCore

@Suite struct PublishAddressSettingTests {
    private func decode(_ json: String) throws -> VMSettings { try JSONDecoder().decode(VMSettings.self, from: Data(json.utf8)) }

    @Test func unsetKeepsDockerDefaultOfEveryInterface() throws {
        let settings = try decode("{}")
        #expect(settings.publishAddress == nil)
        #expect(settings.publishIP("") == "")
        #expect(settings.publishIP("192.168.1.4") == "192.168.1.4")
    }

    @Test func settingAppliesOnlyWhenNoAddressWasAsked() throws {
        let settings = try decode(#"{"publish_address":"127.0.0.1"}"#)
        #expect(settings.publishIP("") == "127.0.0.1")
        #expect(settings.publishIP("0.0.0.0") == "0.0.0.0")
        #expect(try decode(#"{"publish_address":"::1"}"#).publishIP("") == "::1")
    }

    @Test func invalidAddressRefusesTheFileAndSurvivesASave() throws {
        #expect(throws: DecodingError.self) { try decode(#"{"publish_address":"localhost"}"#) }
        var edited = VMSettings.defaults()
        let disk = try decode(#"{"publish_address":"127.0.0.1"}"#)
        edited = edited.keepingFileManagedValues(from: disk)
        #expect(try JSONDecoder().decode(VMSettings.self, from: JSONEncoder().encode(edited)).publishAddress == "127.0.0.1")
    }
}
