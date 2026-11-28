import Foundation
import Testing

/// Feature code takes sizes, radii and colours from the design tokens, so a page cannot drift.
@Suite struct DesignLiteralGuardTests {
    /// Only the token files themselves define literals.
    private static let exempt = ["Shared/UI/DesignSystem.swift", "Shared/UI/WorkspaceStyle.swift"]
    private static let rules: [(String, String)] = [
        (#"cornerRadius: *[0-9]"#, "corner radius literal: use Radius.*"),
        (#"Color\(hex|0x[0-9A-Fa-f]{6}"#, "hex colour: use the product tone"),
        (#"\.frame\([^)]*height: *(2[89]|3[0-9]|4[0-9])\b"#, "control-sized height literal: use Control.* or Tile.*"),
        (#"Color\.(red|green|orange)\b|(foregroundStyle\(|tint: )\.(red|green|orange)\b"#, "raw status colour: use Status.*"),
    ]

    @Test func featureCodeUsesTokens() throws {
        var hits: [String] = []
        for url in AppSources.swiftFiles {
            let path = AppSources.relativePath(url)
            if Self.exempt.contains(where: { path.hasPrefix($0) }) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (pattern, why) in Self.rules where text.range(of: pattern, options: .regularExpression) != nil {
                hits.append("\(path): \(why)")
            }
        }
        #expect(hits.isEmpty, "\(hits.joined(separator: "\n"))")
    }
}
