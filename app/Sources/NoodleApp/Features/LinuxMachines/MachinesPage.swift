import SwiftUI

struct MachinesPage: View {
    let env: AppEnvironment
    var showsUsageInHeader = false

    var body: some View {
        @Bindable var nav = env.nav
        VStack(spacing: 0) {
            // Filter chips sit in the page, so the toolbar keeps only the mode switcher in the centre.
            FilterChips(items: [MachinePlatform.linux, .macOS], selection: $nav.machinePlatform) { $0 == .linux ? "Linux" : "macOS" }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.page).padding(.vertical, Space.s)
            Divider()
            switch nav.machinePlatform {
            case .linux: LinuxMachinesPage(env: env)
            case .macOS: MacMachinePage(store: env.macMachine, demo: env.demo, showsUsageInHeader: showsUsageInHeader)
            }
        }
    }
}
