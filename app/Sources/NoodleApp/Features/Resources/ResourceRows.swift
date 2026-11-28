import SwiftUI

// MARK: - Table behaviour shared by Images, Volumes and Networks

extension View {
    /// Standard rows, narrow tracking, a "Delete…" context menu and the Delete key. `deletable` narrows the ids
    /// that may be deleted (built-in networks are not); `menu` adds items above Delete.
    func resourceRows<Menu: View>(selection: Binding<Set<String>>, narrow: Binding<Bool>,
                                  deletable: @escaping (Set<String>) -> [String] = { Array($0) },
                                  confirm: @escaping ([String]) -> Void,
                                  @ViewBuilder menu: @escaping (Set<String>) -> Menu) -> some View {
        standardRows()
            .trackNarrow(narrow)
            .contextMenu(forSelectionType: String.self) { ids in
                let removable = deletable(ids)
                menu(ids)
                Button("Delete…", systemImage: "trash", role: .destructive) { confirm(removable) }.disabled(removable.isEmpty)
            }
            .onDeleteCommand { confirm(deletable(selection.wrappedValue)) }
    }

    func resourceRows(selection: Binding<Set<String>>, narrow: Binding<Bool>,
                      deletable: @escaping (Set<String>) -> [String] = { Array($0) },
                      confirm: @escaping ([String]) -> Void) -> some View {
        resourceRows(selection: selection, narrow: narrow, deletable: deletable, confirm: confirm) { _ in EmptyView() }
    }
}

extension AppEnvironment {
    /// Asks before deleting. Only ids still visible under the current search are deleted.
    func confirmDelete(_ all: [String], visible: [String], selection: Binding<Set<String>>,
                       title: ([String]) -> String, message: String, remove: @escaping @MainActor ([String]) async -> Void) {
        let ids = all.filter(Set(visible).contains)
        guard !ids.isEmpty else { return }
        nav.confirmation = Confirmation(title: title(ids), message: message, confirmLabel: String(localized: "Delete")) {
            await remove(ids)
            selection.wrappedValue.subtract(ids)
        }
    }
}
