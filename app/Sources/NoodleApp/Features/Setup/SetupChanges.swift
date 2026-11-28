import SwiftUI

/// What setup changes on this Mac, said once on the first page: one short line, and the details one click away.
/// Downloads save only verified tools. The other changes wait for the apply step.
struct SetupChangesLine: View {
    static let summary = "Setup adds a Docker context and a few files."

    /// Everything `noodle setup` leaves behind, and what undoes it.
    static let details = [
        "A Docker context named noodle. It is selected only if you choose that.",
        "A launch agent for Noodle. It does not start at login.",
        "The noodle command in ~/.local/bin, and a docker link there if none exists.",
        "Compose and Buildx links in ~/.docker/cli-plugins when they are missing.",
        "A PATH line in your shell profile, only if you allow it.",
        "The Docker CLI is downloaded when missing. Compose and Buildx download on first use.",
        "noodle uninstall removes setup files. Downloaded tools and container data stay.",
        "noodle tools remove deletes the downloaded tools.",
    ]

    @State private var open = false

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(Self.summary).font(.subheadline).foregroundStyle(.secondary)
            Button("See Details") { open.toggle() }
                .buttonStyle(.link).tint(Color(nsColor: .linkColor)).font(.subheadline)
                .popover(isPresented: $open) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        ForEach(Self.details, id: \.self) { line in
                            Text(line).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(Space.page).frame(width: 380)
                }
        }
        .motion(Motion.snappy, value: open)
    }
}
