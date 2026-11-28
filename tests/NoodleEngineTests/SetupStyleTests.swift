import Testing
@testable import noodle

@Suite struct SetupStyleTests {
    private func row(_ raw: String) -> SetupStyle.Line { SetupStyle.line(raw, home: "/Users/me") }

    @Test func plainLinesBecomeAlignedRows() {
        #expect(row("docker: using /Users/me/.noodle/tools/docker") == .row(mark: "✓", label: "docker", text: "~/.noodle/tools/docker"))
        #expect(row("kubectl 1.37.2: downloading") == .row(mark: "↓", label: "kubectl", text: "1.37.2, downloading"))
        #expect(row("linked kubectl into /Users/me/.local/bin") == .row(mark: "✓", label: "kubectl", text: "linked into ~/.local/bin"))
        #expect(row("docker-compose: ready to download on first use") == .row(mark: "·", label: "docker-compose", text: "downloads on first use"))
        #expect(row("Docker context: noodle -> unix:///Users/me/.noodle/run/docker.sock") == .row(mark: "✓", label: "context", text: "noodle → ~/.noodle/run/docker.sock"))
        #expect(row("Docker context currently selected: noodle") == .row(mark: "✓", label: "selected", text: "noodle"))
        #expect(row("Running") == .row(mark: "✓", label: "engine", text: "running"))
    }

    @Test func closingLineKeepsTheCommandAndTipsAreHeld() {
        #expect(row("Setup complete. Try: docker run --rm alpine echo hello") == .ready(text: "Ready. Try", command: "docker run --rm alpine echo hello"))
        #expect(row("Setup complete. Run `noodle start`, then try: docker run --rm alpine echo hello")
            == .ready(text: "Ready. Run `noodle start`, then try", command: "docker run --rm alpine echo hello"))
        #expect(row("CLI retained for removal after app deletion: /Users/me/.local/bin/noodle uninstall") == .tip("Remove Noodle later with `noodle uninstall`"))
        #expect(row("Build local Dockerfiles with `docker --context noodle build .` or `docker --context noodle buildx build .`.") == .tip("Build images with `docker --context noodle build .`"))
    }

    @Test func unknownLinesPassThroughAndNoColourMeansNoEscapes() {
        let line = row("Docker context stays on default. Run noodle setup --use to switch.")
        #expect(line == .row(mark: "·", label: "", text: "Docker context stays on default. Run noodle setup --use to switch."))
        #expect(!SetupStyle.render(row("Running"), color: false).contains("\u{1B}"))
        #expect(SetupStyle.render(row("Running"), color: true).contains("\u{1B}[32m"))
    }
}
