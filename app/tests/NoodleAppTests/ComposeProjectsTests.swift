import Testing
@testable import NoodleApp

@Suite struct ComposeProjectsTests {
    private func c(_ id: String, project: String?, extra: [String: String] = [:], state: String = "running") -> ContainerSummary {
        var labels = extra
        if let project { labels["com.docker.compose.project"] = project }
        return ContainerSummary(id: id, names: ["/" + id], image: "img", state: state, status: "", created: 0, labels: labels)
    }

    @Test func groupsByProjectAndSkipsAppsAndLooseContainers() {
        let dir = ["com.docker.compose.project.working_dir": "/Users/a/shop",
                   "com.docker.compose.project.config_files": "/Users/a/shop/compose.yaml,/Users/a/shop/override.yaml"]
        let projects = ComposeProjects.group([
            c("1", project: "shop", extra: dir), c("2", project: "shop", state: "exited"),
            c("3", project: "noodle-app-n8n"), c("4", project: nil), c("5", project: "blog"),
        ])
        #expect(projects.map(\.name) == ["blog", "shop"])
        let shop = projects[1]
        #expect(shop.containers.count == 2 && shop.runningCount == 1)
        #expect(shop.directory == "/Users/a/shop")
        #expect(shop.configFiles == ["/Users/a/shop/compose.yaml", "/Users/a/shop/override.yaml"])
    }

    @Test func missingWorkingDirIsNilAndFilesAreEmpty() {
        let blog = ComposeProjects.group([c("5", project: "blog")])[0]
        #expect(blog.directory == nil && blog.configFiles.isEmpty && !blog.canRunFromFiles)
    }

    @Test func argumentsForEveryActionKeepSpacedPathsWhole() {
        let project = ComposeProjectInfo(
            name: "shop", directory: "/Users/a/My Shop", configFiles: ["/Users/a/My Shop/compose.yaml", "/Users/a/My Shop/dev override.yaml"],
            containers: [])
        let head = ["--progress", "plain", "-p", "shop", "--project-directory", "/Users/a/My Shop",
                    "-f", "/Users/a/My Shop/compose.yaml", "-f", "/Users/a/My Shop/dev override.yaml"]
        #expect(ComposeProjects.arguments(.up, for: project) == head + ["up", "-d"])
        let byName = ["--progress", "plain", "-p", "shop"]
        #expect(ComposeProjects.arguments(.down(removeVolumes: false), for: project) == byName + ["down"])
        #expect(ComposeProjects.arguments(.down(removeVolumes: true), for: project) == byName + ["down", "--volumes"])
        #expect(ComposeProjects.arguments(.restart, for: project) == byName + ["restart"])
        #expect(ComposeProjects.arguments(.pull, for: project) == head + ["pull"])
    }

    @Test func argumentsWithoutLabelsOmitTheFlags() {
        let project = ComposeProjectInfo(name: "blog", directory: nil, configFiles: [], containers: [])
        #expect(ComposeProjects.arguments(.restart, for: project) == ["--progress", "plain", "-p", "blog", "restart"])
    }
}
