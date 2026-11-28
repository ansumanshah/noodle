import Foundation
import Testing

/// Every plain `String(localized: "…")` key in the code must be in the catalog, or a translator never sees it.
/// Run `scripts/sync-app-strings.sh` to refresh the catalog. Keys with interpolation are checked by that script, not here.
@Suite struct LocalizationCatalogTests {
    @Test func codeKeysAreInTheCatalog() throws {
        let catalog = try Data(contentsOf: AppSources.root.appending(path: "Resources/Localizable.xcstrings"))
        let json = try #require(JSONSerialization.jsonObject(with: catalog) as? [String: Any])
        let keys = Set(try #require(json["strings"] as? [String: Any]).keys)
        let pattern = try Regex(#"String\(localized: "((?:[^"\\]|\\.)*)"\)"#)
        var missing: [String] = []
        for file in AppSources.swiftFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: pattern) {
                let raw = String(match.output[1].substring ?? "")
                // JSON decodes the same escapes (\n, \") a Swift literal uses.
                let key = (try? JSONSerialization.jsonObject(with: Data("[\"\(raw)\"]".utf8)) as? [String])?.first ?? raw
                if !key.contains("\\(") && !keys.contains(key) { missing.append(key) }
            }
        }
        #expect(missing.isEmpty, "Missing from Localizable.xcstrings, run scripts/sync-app-strings.sh: \(missing)")
    }
}
