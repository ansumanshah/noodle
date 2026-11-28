import SwiftUI

extension View {
    /// A selectable list row drawn in the page's product tone (the system List highlight stays grey). Click selects.
    func selectableRow(selected: Bool, action: @escaping () -> Void) -> some View {
        modifier(SelectableRow(selected: selected, action: action))
    }
}

private struct SelectableRow: ViewModifier {
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowHover(hovering, selected: selected)
            .clipShape(.rect(cornerRadius: Radius.control, style: .continuous))
            .contentShape(.rect(cornerRadius: Radius.control, style: .continuous))
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .focusable().focusEffectDisabled()
            .onKeyPress(keys: [.return, .space]) { _ in action(); return .handled }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: Text("Select"), action)
    }
}

extension View {
    /// Up and Down move `selection` through `ids`, so a list of `selectableRow`s works from the keyboard.
    func selectionKeys<ID: Hashable>(_ ids: [ID], selection: Binding<ID?>) -> some View {
        onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard !ids.isEmpty else { return .ignored }
            let current = selection.wrappedValue.flatMap(ids.firstIndex(of:))
            let next = press.key == .downArrow ? min((current ?? -1) + 1, ids.count - 1) : max((current ?? ids.count) - 1, 0)
            selection.wrappedValue = ids[next]
            return .handled
        }
    }
}
