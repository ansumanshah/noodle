import SwiftUI

/// The Models chat shortcut toggle, shown in Appearance settings.
struct QuickAskSection: View {
    @AppStorage(QuickAsk.defaultsKey) private var enabled = true
    var body: some View {
        Section {
            Toggle("Open Models chat with Control-Option-Space", isOn: $enabled)
                .onChange(of: enabled) { QuickAsk.apply() }
        } header: { Text("Shortcut") } footer: {
            Text("Works from any app, including when Noodle's window is closed.")
        }
    }
}
