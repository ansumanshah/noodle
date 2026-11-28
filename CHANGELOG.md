# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are date-based: year, month, then the release number in that month.

## [26.11.7]

### Fixed

- Set Up for Claude Code and Codex works: MLX models now get a 32,768-token context. With the earlier 4,096 limit an agent's first request was refused as too long. GGUF models keep 4,096.

## [26.11.6]

### Added

- Set Up for Claude Code and Codex on the Connections page: one Noodle-owned settings file each, and the command that starts the agent on the local model.

### Changed

- The app icon drops the ground shadow and the three streaks.
- Container rows show the status as a dot and never clip the image name; a project shows only the start or stop button that applies until hovered.

## [26.11.5]

### Fixed

- Hovering a row on Overview shows a soft rounded highlight; the row's status no longer shows clipped behind its buttons.
- The first-container card closes on its own after 20 seconds and no longer says a container that has already exited is running.

### Changed

- The empty Containers page drops the glow and shows plain `docker run` when Docker already points at Noodle.

## [26.11.4]

### Fixed

- The window header no longer slides under the window buttons or the sidebar in a narrow window.

### Changed

- `noodle setup` prints aligned status rows in a terminal; piped output is unchanged.

## [26.11.3]

### Added

- App updates through a signed feed. Earlier versions need one manual upgrade.
- Bonsai 2 27B in the model catalog: Qwen 3.8 27B at 2 bits, the strongest chat model that loads on a 16 GB Mac.
- Inkling 2 Mini (2.5-bit for 24 GB Macs, 4-bit for 32 GB) and Inkling Small (128 GB) in the model catalog.

### Changed

- The model runtime is mlx-serve 26.11.4.

## [26.11.2]

### Added

- A welcome on first launch: pick Models, Containers or Runners, then download a starter model, connect the Docker tools and add a repo from one screen.

## [26.11.1]

First public release.

### Added

- Docker Engine API served from a Swift daemon over a Unix socket, with containers running in one Linux VM through Virtualization.framework and a static Zig guest agent as PID 1.
- Containers, images, volumes, IPv6 networks, Compose, Buildx and BuildKit builds through the standard `docker` CLI (`docker run --rm alpine echo hello`; setup selects the `noodle` context when no other engine is running, otherwise use `--context noodle`), plus amd64 images through Rosetta.
- Local HTTPS, single-node Kubernetes, Linux machines, pods, import from other Docker-compatible engines, and public links.
- Local names with no ports and local HTTPS: containers and Compose services answer at `NAME.localhost` and `NAME.noodle.local` on ports 80 and 443 without root, and `noodle names add NAME PORT` names a dev server already running on your Mac.
- Noodle Models: GGUF and MLX models through one pinned mlx-serve process, a chat page, an OpenAI-compatible endpoint with a required key, `noodle model run`, and `docker model` with Compose `models:`.
- Noodle Runners: GitHub Actions self-hosted runners on your Mac, single-use, in Linux containers or, opt-in for trusted repos, directly on macOS.
- A native SwiftUI window and menu bar app, and the `noodle` CLI (`setup`, `doctor`, `uninstall` and others).
- Apache-2.0 source for the engine, CLI, guest, Mac app and website.

### Known limits

- No independent security review of the privileged-container VM device policy.
- Tested on macOS 27.2. macOS 26, the stated minimum, has not been run.
- Builds are not reproducible.
- `docker model` and Compose `models:` end-to-end cases are pending.

[26.11.7]: https://github.com/ansumanshah/noodle/releases/tag/v26.11.7
[26.11.6]: https://github.com/ansumanshah/noodle/releases/tag/v26.11.6
[26.11.5]: https://github.com/ansumanshah/noodle/releases/tag/v26.11.5
[26.11.4]: https://github.com/ansumanshah/noodle/releases/tag/v26.11.4
