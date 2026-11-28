import SwiftUI

extension Binding {
    /// An alert, dialog or sheet binding for an optional: shown while it holds a value, cleared when dismissed.
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
    }
}
