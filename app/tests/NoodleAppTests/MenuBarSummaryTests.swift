import Foundation
import Testing
@testable import NoodleApp

@Suite struct MenuBarSummaryTests {
    @Test func vmStatsDistinguishUsageFromLimit() throws {
        let running = try JSONDecoder().decode(VMReadiness.self, from: Data(
            #"{"state":"running","vmRunning":true,"guestAgentReady":true,"cpus":2,"memoryMiB":2048,"usage":{"cpus":2,"memoryMiB":2048,"memoryUsed":33554432}}"#.utf8))
        #expect(MenuBarSummary.vmStats(running, cpuPercent: 3) ==
                "CPU 3% · 2 vCPU · Memory \(Fmt.bytes(32 << 20)) / \(Fmt.bytes(2048 << 20))")
        var olderDaemon = running
        olderDaemon.usage = nil
        #expect(MenuBarSummary.vmStats(olderDaemon, cpuPercent: nil) ==
                "2 vCPU · Memory limit \(Fmt.bytes(2048 << 20))")
    }

    private func c(_ name: String, state: String = "running", status: String = "Up 1 hour", project: String? = nil, service: String? = nil,
                   image: String = "app", ports: [(Int, Int)] = []) -> ContainerSummary {
        var labels: [String: String] = [:]
        if let project { labels["com.docker.compose.project"] = project }
        if let service { labels["com.docker.compose.service"] = service }
        return ContainerSummary(id: name + "id", names: ["/" + name], image: image, state: state, status: status, created: 0,
                                ports: ports.map { PortMapping(ip: "0.0.0.0", privatePort: $0.1, publicPort: $0.0, type: "tcp") }, labels: labels)
    }

    @Test func projectShowsCountAndFailedMember() {
        let list = [c("shop-web-1", project: "shop", service: "web"), c("shop-worker-1", state: "exited", status: "Exited (1) 2 minutes ago", project: "shop", service: "worker"),
                    c("shop-db-1", project: "shop", service: "db")]
        let summary = MenuBarSummary.make(containers: list, machines: [], isUp: true)
        #expect(summary.items.first?.title == "shop · 2 of 3")
        #expect(summary.items.first?.failure?.text == "worker exited with code 1")
        #expect(summary.items.first?.destination == .project("shop"))
        #expect(summary.items.first?.failure?.containerID == "shop-worker-1id")
    }

    @Test func failureRowsFollowTheOverviewClassification() {
        let list = [c("shop-web-1", project: "shop", service: "web"),
                    c("shop-api-1", state: "restarting", status: "Restarting (1) 5 seconds ago", project: "shop", service: "api"),
                    c("job-1", state: "exited", status: "Exited (143) 2 minutes ago", project: "jobs", service: "job"),
                    c("job-2", project: "jobs", service: "queue")]
        let summary = MenuBarSummary.make(containers: list, machines: [], isUp: true)
        let shop = summary.items.first { $0.id == "project:shop" }
        let jobs = summary.items.first { $0.id == "project:jobs" }
        #expect(shop?.failure?.text == "api keeps restarting")
        #expect(jobs?.failure == nil)
    }

    @Test func unhealthyProjectMemberKeepsItsOwnFailureDestination() {
        let list = [c("shop-api-1", status: "Up 1 hour (unhealthy)", project: "shop", service: "api"),
                    c("shop-web-1", project: "shop", service: "web")]
        let item = MenuBarSummary.make(containers: list, machines: [], isUp: true).items.first
        #expect(item?.destination == .project("shop"))
        #expect(item?.failure?.text == "api is unhealthy")
        #expect(item?.failure?.containerID == "shop-api-1id")
    }

    @Test func looseFailuresUseStateSpecificWordsAndIgnoreOldExits() {
        let list = [c("a", state: "restarting"), c("b", state: "dead"), c("c", status: "Up 1 hour (unhealthy)"),
                    c("old", state: "exited", status: "Exited (1) 2 days ago"),
                    c("stopped", state: "exited", status: "Exited (143) 2 minutes ago")]
        let items = MenuBarSummary.make(containers: list, machines: [], isUp: true).items
        #expect(items.map(\.title) == ["a keeps restarting", "b is dead", "c is unhealthy"])
        #expect(items.allSatisfy { $0.failed })
    }

    @MainActor @Test func refreshReloadsTheSelectedMachinesDiskUse() async {
        var diskUsed = "1 GiB"
        var memory = 1024
        let store = LinuxMachinesStore { args, _ in
            switch args {
            case ["machine", "list", "--json"]:
                return CLI.Result(code: 0, output: """
                [{"name":"dev","state":"running","distro":"ubuntu","image":"ubuntu:24.04","cpus":2,"memoryMiB":1024,"diskGiB":20},
                 {"name":"alpine-test","state":"running","distro":"alpine","image":"alpine:3.22","cpus":1,"memoryMiB":\(memory),"diskGiB":10}]
                """)
            case ["machine", "status", "alpine-test"]:
                return CLI.Result(code: 0, output: "resources: 1 CPUs, \(memory) MiB memory, 10 GiB disk (\(diskUsed) used)")
            default: return CLI.Result(code: 1, output: "Unexpected command")
            }
        }
        store.configure(demo: false)
        await store.reload(selected: "alpine-test")
        #expect(store.info["alpine-test"]?.diskUsed == "1 GiB")
        diskUsed = "2 GiB"
        memory = 2048
        await store.reload(selected: "alpine-test")
        #expect(store.info["alpine-test"]?.diskUsed == "2 GiB")
        #expect(store.items.first { $0.name == "alpine-test" }?.memoryMiB == 2048)
        #expect(store.info["dev"] == nil)
    }

    @Test func looseContainerOpensItself() {
        let list = [c("db", state: "exited", status: "Exited (2) 1 minute ago")]
        let item = MenuBarSummary.make(containers: list, machines: [], isUp: true).items.first
        #expect(item?.destination == .container("dbid") && item?.failed == true)
    }

    @Test func cleanExitIsNotAProblemAndStoppedProjectIsHidden() {
        let list = [c("blog-1", state: "exited", status: "Exited (0) 3 days ago", project: "blog")]
        #expect(MenuBarSummary.make(containers: list, machines: [], isUp: true).items.isEmpty)
    }

    @Test func webPortShowsAndOpensTheLocalNameWhenOneExists() {
        let list = [c("web", ports: [(8080, 80)])]
        let names = LocalNameTable(entries: [.init(host: "web.localhost", containerID: String(list[0].id.prefix(12)))])
        let port = MenuBarSummary.make(containers: list, machines: [], isUp: true, names: names).ports.first
        #expect(port?.title.hasPrefix("web.localhost") == true)
        #expect(port?.endpoint.url?.absoluteString == "http://web.localhost")
        #expect(MenuBarSummary.make(containers: list, machines: [], isUp: true).ports.first?.title.hasPrefix("localhost:8080") == true)
    }

    @Test func unknownPortsCopyRatherThanOpenABrowser() {
        let list = [c("kafka", image: "apache/kafka", ports: [(9092, 9092)])]
        #expect(MenuBarSummary.make(containers: list, machines: [], isUp: true).ports.map(\.copies) == [true])
    }

    @Test func udpCopiesAndTlsOpensWithTheCorrectScheme() {
        var list = c("dns", ports: [])
        list.ports = [PortMapping(ip: "0.0.0.0", privatePort: 8080, publicPort: 8080, type: "udp"),
                      PortMapping(ip: "0.0.0.0", privatePort: 443, publicPort: 8443, type: "tcp"),
                      PortMapping(ip: "0.0.0.0", privatePort: 80, publicPort: 8081, type: "tcp"),
                      PortMapping(ip: "::", privatePort: 80, publicPort: 8081, type: "tcp")]
        let ports = MenuBarSummary.make(containers: [list], machines: [], isUp: true).ports
        #expect(ports.map(\.number) == [8080, 8081, 8443])
        #expect(ports.map(\.copies) == [true, false, false])
        #expect(ports.last?.endpoint.url?.absoluteString == "https://localhost:8443")
    }

    @Test func databasePortsCopyAndWebPortsOpen() {
        let list = [c("web", ports: [(3000, 3000)]), c("db", image: "postgres:17", ports: [(5432, 5432)])]
        let ports = MenuBarSummary.make(containers: list, machines: [], isUp: true).ports
        #expect(ports.map(\.number) == [3000, 5432])
        #expect(ports.map(\.copies) == [false, true])
        #expect(ports.allSatisfy { $0.title.count <= 30 })
    }

    @Test func listsStopAtFiveWithTheFullCount() {
        let list = (0..<8).map { c("c\($0)", ports: [(4000 + $0, 80)]) }
        let summary = MenuBarSummary.make(containers: list, machines: [], isUp: true)
        #expect(summary.items.count == 5 && summary.totalItems == 8)
        #expect(summary.ports.count == 5 && summary.totalPorts == 8)
    }

    @Test func standaloneFailurePrecedesHealthyProjectsBeforeTruncation() {
        let healthy = (0..<5).map { c("web\($0)", project: "project\($0)") }
        let failure = c("worker", state: "restarting")
        let summary = MenuBarSummary.make(containers: healthy + [failure], machines: [], isUp: true)
        #expect(summary.items.first?.destination == .container("workerid"))
        #expect(summary.items.first?.failed == true)
        #expect(summary.items.count == 5 && summary.totalItems == 6)
    }

    @Test func projectAndStandaloneFailuresBothPrecedeHealthyItems() {
        let healthy = (0..<5).map { c("web\($0)", project: "project\($0)") }
        let failures = [c("api", state: "restarting", project: "trouble"), c("worker", state: "dead")]
        let summary = MenuBarSummary.make(containers: healthy + failures, machines: [], isUp: true)
        let destinations = summary.items.prefix(2).map(\.destination)
        #expect(destinations.contains(.project("trouble")) && destinations.contains(.container("workerid")))
        #expect(summary.items.dropFirst(2).allSatisfy { !$0.failed && $0.failure == nil })
    }

    @Test func stoppedEngineHidesContainersButKeepsMachines() {
        let machine = LinuxMachine(name: "dev", state: "running", distro: "ubuntu", image: "ubuntu:24.04", cpus: 2, memoryMiB: 2048, diskGiB: 20)
        let summary = MenuBarSummary.make(containers: [c("web", ports: [(3000, 3000)])], machines: [machine], isUp: false)
        #expect(summary.items.isEmpty && summary.ports.isEmpty)
        #expect(summary.machines.map(\.title) == ["dev · running"])
    }

    @Test func machineStatusParses() {
        let text = """
        name:     dev
        state:    running
        resources: 2 CPUs, 4096 MiB memory, 40 GiB disk (8.2 GiB used)
        share:    /Users/a/Code at /mnt/share
        address:  192.168.64.12
        """
        let info = LinuxMachineInfo.parse(text)
        #expect(info == LinuxMachineInfo(address: "192.168.64.12", sharedFolder: "/Users/a/Code", diskUsed: "8.2 GiB"))
        #expect(LinuxMachineInfo.parse("share:    none\naddress:  \n") == LinuxMachineInfo())
    }

    @Test func subtitleDropsTheDigest() {
        let m = LinuxMachine(name: "d", state: "stopped", distro: "ubuntu", image: "ubuntu:24.04@sha256:abc", cpus: 1, memoryMiB: 512, diskGiB: 5)
        #expect(m.subtitle == "Ubuntu 24.04")
        #expect(m.memoryText == "512 MiB")
    }
}
