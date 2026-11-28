import Testing
@testable import NoodleEngine

@Test func dockerfileRefsFindEveryExternalImage() {
    let text = """
    ARG BASE=registry.local:5000/team/base
    ARG TAG=1
    FROM --platform=linux/arm64 ${BASE}:${TAG} AS build
    RUN --mount=type=bind,from=tools:2,target=/t true
    COPY --from=helper:3 /a /a
    COPY --from=build /b /b
    COPY --from=0 /c /c
    FROM scratch
    FROM build
    ADD --from=other/img@sha256:\(String(repeating: "a", count: 64)) /d /d
    """
    let refs = DockerfileRefs.externalImages(in: text, args: [:])
    #expect(refs.contains("registry.local:5000/team/base:1"))
    #expect(refs.contains("tools:2"))
    #expect(refs.contains("helper:3"))
    #expect(refs.contains("other/img@sha256:" + String(repeating: "a", count: 64)))
    #expect(!refs.contains("scratch"))
    #expect(!refs.contains("build"))
    #expect(!refs.contains("0"))
}

@Test func dockerfileRefsHonourBuildArgOverrides() {
    let text = "ARG BASE=alpine:3.20\nFROM ${BASE}\nFROM $UNSET\n"
    #expect(DockerfileRefs.externalImages(in: text, args: ["BASE": "local/only:9"]) == ["local/only:9"])
    #expect(DockerfileRefs.externalImages(in: text, args: [:]) == ["alpine:3.20"])
}
