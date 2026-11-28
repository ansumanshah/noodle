import Foundation
import Testing
@testable import NoodleApp

/// A daemon that only answers `inspect`, with a finish time the test can change.
private final class InspectOnly: DockerService, @unchecked Sendable {
    var finishedAt = "2026-11-07T10:00:00Z"
    func inspect(_ id: String) async throws -> ContainerDetails {
        try JSONDecoder().decode(ContainerDetails.self, from: Data(#"{"Id":"\#(id)","State":{"FinishedAt":"\#(finishedAt)"}}"#.utf8))
    }
    func ping() async throws {}
    func info() async throws -> DaemonInfo { fatalError() }
    func containers() async throws -> [ContainerSummary] { [] }
    func images() async throws -> [ImageSummary] { [] }
    func volumes() async throws -> [VolumeSummary] { [] }
    func networks() async throws -> [NetworkSummary] { [] }
    func start(_ id: String) async throws {}
    func stop(_ id: String) async throws {}
    func restart(_ id: String) async throws {}
    func removeContainer(_ id: String) async throws {}
    func removeImage(_ id: String) async throws {}
    func removeVolume(_ name: String) async throws {}
    func removeNetwork(_ id: String) async throws {}
    func events() async throws -> AsyncThrowingStream<DockerEvent, Error> { fatalError() }
    func logs(_ id: String, tty: Bool, tail: Int) async throws -> AsyncThrowingStream<LogEntry, Error> { fatalError() }
    func stats(_ id: String) async throws -> AsyncThrowingStream<StatsSample, Error> { fatalError() }
    func exec(_ id: String, argv: [String], timeout: Double) async throws -> DockerAPI.ExecResult { fatalError() }
    func archive(_ id: String, path: String) async throws -> Data { Data() }
    func list(_ id: String, path: String) async throws -> [FileEntry] { [] }
}

@MainActor @Suite struct OverviewLogicTests {
    private func container(_ id: String, state: String = "exited", status: String = "Exited (1) 5 minutes ago",
                           ports: [PortMapping] = []) -> ContainerSummary {
        ContainerSummary(id: id, names: ["/" + id], image: "app", state: state, status: status, created: 0, ports: ports)
    }

    // MARK: disk

    @Test func digestOnlyImageStaysAndStoppedContainersFreeTheirImages() throws {
        let body = #"""
        {"LayersSize":1000,
         "Images":[{"Id":"a","RepoTags":[],"RepoDigests":[],"Size":100},
                   {"Id":"b","RepoTags":["<none>:<none>"],"RepoDigests":["app@sha256:1"],"Size":200},
                   {"Id":"c","RepoTags":[],"RepoDigests":[],"Size":300},
                   {"Id":"d","RepoTags":[],"RepoDigests":[],"Size":400},
                   {"Id":"e","RepoTags":["app:1"],"RepoDigests":["<none>@<none>"],"Size":500}],
         "Containers":[{"State":"exited","SizeRw":10,"ImageID":"c"},{"State":"running","SizeRw":5,"ImageID":"d"}],
         "Volumes":[{"UsageData":{"Size":50}}]}
        """#
        let disk = try #require(OverviewDiskSource.summarize(Data(body.utf8)))
        // a: nothing uses it. b: has a digest, which prune keeps. c: only a stopped container uses it. d: a running one does.
        #expect(disk.untaggedImages == 2 && disk.stoppedContainers == 1)
        #expect(disk.reclaimable == 410)
        #expect(disk.used == 1065)
    }

    @Test func removableThingsWithZeroBytesStillOfferCleanUp() throws {
        let body = #"{"Images":[{"Id":"a","RepoTags":[],"Size":0}],"Containers":[{"State":"exited","SizeRw":0,"ImageID":"a"}]}"#
        let disk = try #require(OverviewDiskSource.summarize(Data(body.utf8)))
        #expect(disk.used == 0 && disk.reclaimable == 0)
        #expect(disk.canClean)
    }

    // MARK: endpoints

    @Test func endpointKeepsAddressSchemeAndProtocol() throws {
        func mapping(_ ip: String?, _ privatePort: Int, _ port: Int, _ type: String = "tcp") -> PortMapping {
            PortMapping(ip: ip, privatePort: privatePort, publicPort: port, type: type)
        }
        let wildcard = try #require(PortEndpoint(mapping("0.0.0.0", 3000, 3000)))
        #expect(wildcard.address == "localhost:3000" && wildcard.url?.absoluteString == "http://localhost:3000")
        let bound = try #require(PortEndpoint(mapping("127.0.0.2", 80, 8080)))
        #expect(bound.address == "127.0.0.2:8080" && bound.url?.absoluteString == "http://127.0.0.2:8080")
        let tls = try #require(PortEndpoint(mapping("0.0.0.0", 443, 8443)))
        #expect(tls.url?.absoluteString == "https://localhost:8443")
        let udp = try #require(PortEndpoint(mapping("0.0.0.0", 8080, 8080, "udp")))
        #expect(udp.url == nil)
        #expect(PortKind.of(udp, image: "app") == .other)
        #expect(PortKind.of(tls, image: "app") == .web)
        let six = try #require(PortEndpoint(mapping("::1", 80, 8080)))
        #expect(six.address == "[::1]:8080")
    }

    @Test func endpointsCollapseDualStackAndSkipStoppedContainers() {
        let ports = [PortMapping(ip: "0.0.0.0", privatePort: 80, publicPort: 8080, type: "tcp"),
                     PortMapping(ip: "::", privatePort: 80, publicPort: 8080, type: "tcp"),
                     PortMapping(ip: "127.0.0.2", privatePort: 80, publicPort: 8080, type: "tcp"),
                     PortMapping(ip: nil, privatePort: 80, publicPort: nil, type: "tcp")]
        #expect(PortEndpoint.list(container("web", state: "running", status: "Up", ports: ports)).map(\.address)
                == ["127.0.0.2:8080", "localhost:8080"])
        #expect(PortEndpoint.list(container("web", status: "Exited (0) 1 minute ago", ports: ports)).isEmpty)
    }

    // MARK: failures

    @Test func pausedContainersStillHoldMemory() {
        let items = [container("running", state: "running"), container("paused", state: "paused"),
                     container("stopped"), container("restarting", state: "restarting")]
        #expect(OverviewMemory.ids(items) == ["running", "paused"])
    }

    @Test func oneShotMemorySubtractsCacheAndRejectsMissingData() {
        #expect(OverviewMemory.bytes(Data(#"{"memory_stats":{"usage":1024,"stats":{"inactive_file":128}}}"#.utf8)) == 896)
        #expect(OverviewMemory.bytes(Data(#"{"memory_stats":{"usage":0}}"#.utf8)) == 0)
        #expect(OverviewMemory.bytes(Data(#"{"memory_stats":{}}"#.utf8)) == nil)
        #expect(OverviewMemory.bytes(Data(#"{"message":"not found"}"#.utf8)) == nil)
    }

    @Test func unhealthyAndRestartingContainersHaveNoExitAge() {
        #expect(!OverviewProblems.hasExitTime(container("unhealthy", state: "running", status: "Up (unhealthy)")))
        #expect(!OverviewProblems.hasExitTime(container("loop", state: "restarting")))
        #expect(OverviewProblems.hasExitTime(container("dead", state: "dead")))
    }

    @Test func exitOlderThanADayIsDroppedByItsTimestamp() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let c = container("api", status: "Exited (1) 30 hours ago")
        #expect(OverviewProblems.failing([c], now: now).isEmpty)
        #expect(OverviewProblems.failing([container("api", status: "Exited (1) 5 hours ago")], now: now).count == 1)
        // The inspected time decides once it is known, whatever the words say.
        let fresh = container("api", status: "Exited (1) 5 hours ago")
        #expect(OverviewProblems.failing([fresh], finished: ["api": now.addingTimeInterval(-30 * 3600)], now: now).isEmpty)
        #expect(OverviewProblems.failing([fresh], finished: ["api": now.addingTimeInterval(-3600)], now: now).count == 1)
    }

    @Test func unhealthyIsNotLabelledRunning() {
        #expect(OverviewProblems.stateLabel(container("a", state: "running", status: "Up 2 hours (unhealthy)")) == "Unhealthy")
        #expect(OverviewProblems.stateLabel(container("a", state: "running", status: "Up 2 hours")) == "Running")
        #expect(OverviewProblems.stateLabel(container("a")) == "Exited (code 1)")
    }

    @Test func zeroFinishTimeIsNoTime() {
        #expect(OverviewModel.exitDate("0001-01-01T00:00:00Z") == nil)
        #expect(OverviewModel.exitDate("2026-11-07T10:00:00.123456789Z") != nil)
    }

    @Test func eachNewFailureGetsItsOwnExitTime() async throws {
        let service = InspectOnly()
        let model = OverviewModel()
        model.learnExits(["api"], service: service)
        try await waitUntil { model.finished["api"] != nil }
        let first = try #require(model.finished["api"])
        // The container recovers: its time goes with the failure.
        model.learnExits([], service: service)
        #expect(model.finished["api"] == nil)
        // It fails again later: the new time is read, not the old one.
        service.finishedAt = "2026-11-07T12:00:00Z"
        model.learnExits(["api"], service: service)
        try await waitUntil { model.finished["api"] != nil }
        let second = try #require(model.finished["api"])
        #expect(second > first)
    }
}
