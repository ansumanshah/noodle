import SwiftUI

struct DetailRouter: View {
    let env: AppEnvironment
    var sidebarHidden = false
    var body: some View {
        Group {
            switch env.nav.route {
            case .overview: OverviewPage(env: env)
            case .containers: ContainersPage(env: env)
            case .compose: ComposePage(env: env)
            case .images: ImagesPage(env: env)
            case .volumes: VolumesPage(env: env)
            case .networks: NetworksPage(env: env)
            case .machines: MachinesPage(env: env, showsUsageInHeader: sidebarHidden)
            case .kubernetes: KubernetesPage(store: env.kubernetes, search: env.nav.search)
            case .builds: BuildsPage(env: env)
            case .runners: RunnersPage(env: env)
            case .runnerRepos: RunnerReposPage(env: env)
            case .runnerJobs: RunnerJobsPage(env: env)
            case .runnerCaches: RunnerCachesPage(env: env)
            case .apps: AppsPage(env: env)
            case .chat, .create, .library, .connections:
                ModelsPage(demo: env.demo, section: env.nav.route, windowVisible: env.sync.windowVisible,
                           open: { env.nav.open(.route($0)) })
            }
        }
        .id(env.nav.route)
        .environment(\.productTone, env.nav.route.tone)
        // Links, progress and switches take the mode's ink; buttons keep their own styles.
        .tint(env.nav.route.tone.ink)
        .buttonStyle(.neutralAction)   // every page button is one control; explicit styles below win
        .environment(\.docsURL, env.nav.route.docsURL)
        .transition(.opacity)
        .motion(Motion.standard, value: env.nav.route)
    }
}
