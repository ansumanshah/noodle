import Foundation

/// Closing the last window hands the menu bar to a fresh lightweight process and quits this one. Work this
/// process is running dies with it (a CLI pipe closes, a reply stream drops), so while any runs it stays instead.
struct WindowCloseWork: Equatable {
    var macMachine = false
    /// Model download, delete, server start or a streaming chat reply (`ModelsPageStore.busy`).
    var models = false
    var modelCreate = false
    var appInstalls = 0
    var composeActions = 0
    var kubernetes: KubernetesStore.Action?

    var keepsProcess: Bool {
        macMachine || models || modelCreate || appInstalls > 0 || composeActions > 0 || kubernetes != nil
    }

    /// The Models stores are read only if they exist (the live one loads chat history). The other stores are cheap to
    /// make, and one made here holds no work, so the window closes as before.
    @MainActor static func current(_ env: AppEnvironment) -> WindowCloseWork {
        let models = ModelsPage.existingStore(demo: env.demo)
        return WindowCloseWork(macMachine: env.macMachine.isActive, models: models?.busy ?? false,
                               modelCreate: models.map { ModelCreateStore.existing(models: $0)?.running ?? false } ?? false,
                               appInstalls: env.apps.progress.count, composeActions: env.compose.progress.count,
                               kubernetes: env.kubernetes.action)
    }
}
