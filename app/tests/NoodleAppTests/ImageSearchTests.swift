import Foundation
import Testing
@testable import NoodleApp

@Test func imageSearchEncodesQueryAndRequestsBoundedResults() {
    #expect(DockerAPI.imageSearchTarget("a/b &+?#% ü") == "/images/search?term=a%2Fb%20%26%2B%3F%23%25%20%C3%BC&limit=25")
}

@Test func imageSearchDecodesDockerFields() throws {
    let data = Data(#"[{"name":"library/alpine","description":"Small image","star_count":42,"is_official":true,"is_automated":false}]"#.utf8)
    let result = try #require(JSONDecoder().decode([ImageSearchResult].self, from: data).first)
    #expect(result.name == "library/alpine")
    #expect(result.description == "Small image")
    #expect(result.starCount == 42)
    #expect(result.isOfficial)
}

@Test(arguments: [
    ("registry.example:5000/team/postgres:17", ImageKind.database),
    ("redis:7-alpine", .cache),
    ("node:22", .runtime),
    ("nginx@sha256:0123456789abcdef", .web),
    ("team/postgres-backup", .generic),
    ("<untagged>", .generic),
]) func imageKindUsesRepositoryName(reference: String, expected: ImageKind) {
    #expect(ImageKind(reference: reference) == expected)
}
