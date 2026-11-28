import AppKit

/// Replaces the pasteboard with `text`. Concealed text (secrets) is hidden from clipboard managers and
/// cleared after 60 seconds unless something else was copied since.
@MainActor func copyToPasteboard(_ text: String, concealed: Bool = false) {
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(text, forType: .string)
    guard concealed else { return }
    board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    let count = board.changeCount
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(60))
        if board.changeCount == count { board.clearContents() }
    }
}
