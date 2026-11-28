import Foundation

/// The one match rule for type-to-filter: a blank query matches everything; otherwise the trimmed query
/// must appear, ignoring case, in any of the visible name or secondary fields.
/// The toolbar search field (`ToolbarSearch` in WindowToolbar) supplies Command-F focus and Escape-to-clear.
enum ListFilter {
    static func matches(_ query: String, _ fields: String?...) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || fields.contains { $0?.localizedCaseInsensitiveContains(q) ?? false }
    }
}
