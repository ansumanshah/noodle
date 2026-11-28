# Contributing

Noodle is at v26.11.8 and its feature set is frozen. The most useful changes fix broken flows, UI correctness, Docker compatibility and release reliability. Open an issue to discuss a new feature before you write it.

Install the toolchains with `mise trust && mise install`. Run `just test-unit` for engine changes, `just test-app` for app changes, and exercise affected Docker behaviour with `just e2e`. Run `just test-release-source` and `just test-source-preview` for packaging changes. The website uses `bun install --frozen-lockfile` and `bun run build` from `website/`, and `bun run typecheck` there too.

The Swift disk tests need the pinned e2fsprogs tools in `build/resources`. `just resources` stages them along with the guest resources. The full VM suite requires an Apple silicon Mac and a matching kernel. Hosted CI cannot replace that check.

Update the [protocol](docs/architecture/protocol.md) before changing either side of a wire operation. Keep daemon code free of UI frameworks. Run GUI checks with `NOODLE_NO_ACTIVATE=1` and disposable data.

Contributions use the [Developer Certificate of Origin](https://developercertificate.org/). Sign off each commit with `git commit --signoff` and submit contributions under Apache-2.0. Report security problems through [SECURITY.md](SECURITY.md).
