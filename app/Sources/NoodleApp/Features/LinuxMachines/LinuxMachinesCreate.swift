import SwiftUI

/// A distro and a name. CPUs, memory, disk and a custom image sit behind one expansion.
struct LinuxMachinesCreateSheet: View {
    let store: LinuxMachinesStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var distro = "ubuntu"
    @State private var showMore = false
    @State private var image = ""
    @State private var cpus = 2
    @State private var memoryMiB = 2048
    @State private var diskGiB = 20

    private var customImage: String? {
        let trimmed = image.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var nameTaken: Bool { store.items.contains { $0.name == name } }
    private var valid: Bool {
        name.range(of: "^[a-z0-9][a-z0-9-]{0,30}$", options: .regularExpression) != nil && !nameTaken
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Machine").font(.title2.weight(.semibold))
            Form {
                Picker("Distribution", selection: $distro) {
                    Text("Ubuntu 24.04").tag("ubuntu")
                    Text("Alpine 3.22").tag("alpine")
                }.pickerStyle(.segmented)
                TextField("Name", text: $name, prompt: Text("dev"))
                if nameTaken {
                    Text("A machine named \(name) already exists.").font(.subheadline).foregroundStyle(Status.warning)
                } else if !name.isEmpty && !valid {
                    Text("Use lowercase letters, digits and dashes.").font(.subheadline).foregroundStyle(.secondary)
                }
                DisclosureGroup("More Options", isExpanded: $showMore) {
                    Stepper("CPUs: \(cpus)", value: $cpus, in: 1...max(2, ProcessInfo.processInfo.processorCount))
                    Stepper("Memory: \(LinuxMachine.size(mebibytes: memoryMiB))", value: $memoryMiB, in: 256...65536, step: 256)
                    Stepper("Disk: \(diskGiB) GiB", value: $diskGiB, in: 1...16384)
                    TextField("Custom image", text: $image, prompt: Text("Optional, replaces the distro"))
                }
            }.disabled(store.busy)
            if let error = store.error {
                Text(error).font(.callout).foregroundStyle(Status.error).textSelection(.enabled)
            }
            if store.busy { ProgressView("Creating machine. The first download can take minutes.") }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.busy)
                Button("Create") {
                    Task {
                        if await store.create(name: name, distro: distro, image: customImage,
                                              cpus: cpus, memoryMiB: memoryMiB, diskGiB: diskGiB) { dismiss() }
                    }
                }.buttonStyle(.primaryAction).keyboardShortcut(.defaultAction).disabled(!valid || store.busy)
            }
        }
        .padding(Space.xl).frame(width: 460)
        .interactiveDismissDisabled(store.busy)
        .motion(Motion.standard, value: showMore)
        .onAppear { store.error = nil }
    }
}
