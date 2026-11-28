import Testing
@testable import NoodleImages

@Suite struct ImageReferenceTests {
    @Test func hubDefaults() throws {
        let r = try ImageReference.parse("ubuntu")
        #expect(r.domain == "docker.io")
        #expect(r.path == "library/ubuntu")
        #expect(r.tag == "latest")
        #expect(r.registryHost == "registry-1.docker.io")
        #expect(r.familiar == "ubuntu:latest")
        #expect(r.description == "docker.io/library/ubuntu:latest")
    }

    @Test func userRepoWithTag() throws {
        let r = try ImageReference.parse("nginx/unit:1.32")
        #expect(r.path == "nginx/unit")
        #expect(r.tag == "1.32")
        #expect(r.familiar == "nginx/unit:1.32")
    }

    @Test func customRegistryAndPort() throws {
        let r = try ImageReference.parse("localhost:5000/team/app:dev")
        #expect(r.domain == "localhost:5000")
        #expect(r.path == "team/app")
        #expect(r.tag == "dev")
        #expect(r.isLocalHTTPAllowed)
        let g = try ImageReference.parse("ghcr.io/owner/repo")
        #expect(g.domain == "ghcr.io")
        #expect(g.tag == "latest")
        #expect(!g.isLocalHTTPAllowed)
        #expect(g.familiar == "ghcr.io/owner/repo:latest")
    }

    @Test func digestReference() throws {
        let d = "sha256:" + String(repeating: "a", count: 64)
        let r = try ImageReference.parse("alpine@\(d)")
        #expect(r.digest == d)
        #expect(r.tag == nil)
        #expect(r.path == "library/alpine")
        #expect(r.reference == d)
        let both = try ImageReference.parse("alpine:3.20@\(d)")
        #expect(both.tag == "3.20")
        #expect(both.digest == d)
    }

    @Test func hubAliases() throws {
        #expect(try ImageReference.parse("index.docker.io/library/redis:7").domain == "docker.io")
        #expect(try ImageReference.parse("docker.io/redis").path == "library/redis")
    }

    @Test(arguments: ["", "UPPER/case", "a b", "repo:", "repo:-bad", "a//b", "repo@sha256:zz", "/lead"])
    func rejectsInvalid(_ s: String) {
        #expect(throws: (any Error).self) { try ImageReference.parse(s) }
    }

    @Test func platformParsing() {
        #expect(Platform.parse("linux/amd64") == Platform(os: "linux", architecture: "amd64"))
        #expect(Platform.parse("amd64") == .amd64)
        #expect(Platform.parse("x86_64") == .amd64)
        #expect(Platform.parse("arm64")?.variant == "v8")
        #expect(Platform.parse("linux/arm64/v8")?.architecture == "arm64")
        #expect(Platform.arm64.matches(os: "linux", architecture: "arm64", variant: nil))
        #expect(Platform.arm64.matches(os: "linux", architecture: "arm64", variant: "v8"))
        #expect(!Platform.arm64.matches(os: "linux", architecture: "amd64", variant: nil))
    }

    @Test func mediaTypes() {
        #expect(MediaType.guestMedia(forLayer: MediaType.dockerLayerGzip) == "gzip")
        #expect(MediaType.guestMedia(forLayer: MediaType.ociLayerZstd) == "zstd")
        #expect(MediaType.guestMedia(forLayer: MediaType.ociLayerTar) == "tar")
    }
}
