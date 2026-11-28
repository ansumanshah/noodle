import SwiftUI

/// A page's toolbar button. Pages publish these with `.pageActions`; `WindowToolbar` draws them in its trailing group, so
/// order, size and spacing are owned in one place instead of each page adding its own `ToolbarItem`.
struct PageAction: Identifiable, Equatable {
    /// Also the accessibility identifier, prefixed `toolbar-`.
    let id: String
    let title: LocalizedStringKey
    let symbol: String
    var iconOnly = true
    var disabled = false
    var help: LocalizedStringKey?
    /// Reads page state when pressed, so a closure from an earlier body still acts on the current selection.
    let run: @MainActor () -> Void

    // The closure is left out: a page re-publishes whenever what it shows changes.
    static func == (a: PageAction, b: PageAction) -> Bool {
        a.id == b.id && a.title == b.title && a.symbol == b.symbol && a.iconOnly == b.iconOnly
            && a.disabled == b.disabled && a.help == b.help
    }
}

struct PageActionsKey: PreferenceKey {
    static var defaultValue: [PageAction] { [] }
    static func reduce(value: inout [PageAction], nextValue: () -> [PageAction]) { value += nextValue() }
}

extension View {
    func pageActions(_ actions: [PageAction]) -> some View { preference(key: PageActionsKey.self, value: actions) }
}
