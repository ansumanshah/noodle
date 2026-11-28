# NoodleEngine public API (for the Docker API layer)

`import NoodleEngine` re-exports NoodleCore, NoodleImages and NoodleVM. One `Engine` actor per daemon:

```swift
let engine = Engine()              // paths from NOODLE_HOME / ~/.noodle, vm.json + NOODLE_CPUS / NOODLE_MEMORY_MIB
try await engine.start()           // loads state; boots the VM only if a restart-policy container needs it
await engine.shutdown()            // flush state, stop listeners, power off the VM
```
Host-only calls never boot the VM: list/inspect/create/rename/update(stopped), rm of stopped containers, images (list, tag, rm, save, load, inspect, history), networks, volumes, info, version, events. Guest calls (start, logs, exec, stats, ...) wake it (cold boot logged, about 1 to 2 s). The VM sleeps after 60 s with no running container and no open stream.

Wire models (`DockerModels.swift`) use Docker's exact JSON key names as Swift property names (`Id`, `HostConfig`, ...); decode request bodies and encode responses with plain `JSONDecoder`/`JSONEncoder`. Every failure is `EngineError` with `.httpStatus` (404/409/304/400/503/500) and `.description` as the `message`.

## System
| Docker | Engine |
|---|---|
| `GET /_ping` | `ping() -> String` |
| `GET /version` | `version() -> VersionInfo` (ApiVersion 1.51, Min 1.24) |

| `GET /info` | `info() async -> SystemInfo` |
| `GET /system/df` | `diskUsage() async -> DiskUsage` |
| `GET /events` | `events(since: Int64?, until: Int64?, filters: Filters) -> AsyncStream<EventMessage>` |
`Filters.parse(queryValue)` parses the `filters` parameter (both JSON forms).

Why 1.51, not 1.52 (from the Docker API changelog for 1.48 to 1.52): 1.52 clients read `ImagesUsage`, `ContainersUsage`, `VolumesUsage` and `BuildCacheUsage` from `GET /system/df`, and expect `Status` on `GET /networks/{id}`, `os_type` in stats and `application/x-ndjson` event negotiation. Noodle does none of these yet, so advertising 1.52 would show an empty `docker system df`. The 1.48 to 1.51 changes are additive or deprecations Noodle tolerates. Raise the version after those four are handled. Docker itself is already at 1.57.

`GET /noodle/vm/status` is a read-only startup snapshot for Noodle clients. An
HTTP response establishes that the Docker API is available. `vmRunning` tracks
the host VM start and `guestAgentReady` records the successful control
connection for the current boot. The route does not boot the VM.

## Containers
| Docker | Engine |
|---|---|
| `POST /containers/create` | `createContainer(name:request: ContainerCreateRequest, platform:) async throws -> (id, warnings)`; decode body with `ContainerCreateRequest` (Config fields top level + HostConfig + NetworkingConfig) |
| `GET /containers/json` | `listContainers(all:limit:filters:) -> [ContainerSummary]` |
| `GET /containers/{id}/json` | `inspectContainer(_:) throws -> ContainerInspect` |
| `POST .../start` | `startContainer(_:)`; throws `.notModified` (304) if running |
| `POST .../stop` | `stopContainer(_:signal:timeout:)`; `.notModified` if stopped |
| `POST .../restart` | `restartContainer(_:signal:timeout:)` |
| `POST .../kill` | `killContainer(_:signal:)` (name or number) |
| `POST .../pause`, `unpause` | `pauseContainer`, `unpauseContainer` |
| `POST .../wait` | `waitContainer(_:condition:) async throws -> WaitResult` (`StatusCode`, `Error`) |
| `DELETE /containers/{id}` | `removeContainer(_:force:removeVolumes:)` |
| `POST .../rename` | `renameContainer(_:to:)` |
| `POST .../update` | `updateContainer(_:_: ContainerUpdateRequest) -> [String]` (warnings) |
| `POST .../resize` | `resizeContainer(_:rows:cols:)` |
| `GET .../top` | `top(_:psArgs:) async throws -> TopResult` |
| `GET .../changes` | `changes(_:) async throws -> [FsChange]` |
| `GET .../stats` | `stats(_:stream:oneShot:) throws -> AsyncThrowingStream<StatsJSON, Error>` (1 sample/s) |
| `POST /containers/prune` | `pruneContainers(filters:) async -> ContainerPruneResponse` |
| `GET .../logs` | `logs(_:options: LogOptions) async throws -> GuestStream` |
| `POST .../attach` | `attach(_:stdin:stdout:stderr:logs:) async throws -> GuestStream` (409 unless running) |
| `GET .../export` | `exportContainer(_:) async throws -> GuestStream` (raw tar) |
| `GET/HEAD .../archive` | `archiveGet(_:path:) async throws -> GuestStream` (raw tar; `Engine.pathStat(fromTarHeader:)` on the first 512 bytes gives the `X-Docker-Container-Path-Stat` JSON) |
| `PUT .../archive` | `archivePut(_:path:size:)`: write `size` bytes, `finishWriting()`, `try await readResult()` |
| `POST /commit` | `commitContainer(_:repo:tag:comment:author:changes:config:) async throws -> imageID` |

## Exec
`createExec(_:config: ExecConfig) throws -> id`, `startExec(_:detach:tty:) async throws -> GuestStream?` (nil when detached), `inspectExec(_:) throws -> ExecInspect`, `resizeExec(_:rows:cols:)`. The exit code is recorded when the stream's `.exit` frame is read, so always consume frames until `.exit`.

## Streams (`GuestStream`)
- Multiplexed (attach, exec, logs): `nextFrame()` / `frames` give `StreamFrame(kind: .stdout/.stderr/.exit ...)`. Send input with `writeStdin(_:)`, `closeStdin()`, `resize(rows:cols:)`. Non-TTY Docker output is `[kind(1|2), 0,0,0, size u32 BE] + bytes`; TTY output is the raw payload. `Engine` does not add that header; build it in the API layer (`LogRecord`/`StreamFrame` are in NoodleCore).
- Raw (export, archive, commit): `readChunk()` / `chunks` / `readAll()`; `write(_:)`, `finishWriting()`, `readResult()`.
- `fileDescriptor` exposes the vsock fd for bridging. Always `close()`; no NIO anywhere. Open streams keep the VM awake.

## Images
| Docker | Engine |
|---|---|
| `GET /images/json` | `listImages(all:filters:digests:) async -> [ImageSummary]` |
| `GET /images/{n}/json` | `inspectImage(_:) async throws -> ImageInspect` |
| `GET /images/{n}/history` | `imageHistory(_:) async throws -> [ImageHistoryEntry]` |
| `POST /images/create?fromImage=` | `pullImage(_ fromImage:tag:platform:registryAuth:) -> AsyncThrowingStream<ProgressEvent, Error>`; `ProgressEvent{id,status,current,total}` maps to Docker's `{"status","id","progressDetail":{current,total}}`; layers are unpacked into the guest as they arrive |
| `POST /images/{n}/push` | `pushImage(_:tag:registryAuth:) -> AsyncThrowingStream<ProgressEvent, Error>` |
| `POST /images/{n}/tag` | `tagImage(_:repo:tag:)` |
| `DELETE /images/{n}` | `removeImage(_:force:) async throws -> [ImageDeleteItem]` |
| `GET /images/search` | `searchImages(term:limit:filters:) async throws -> [ImageSearchItem]` |
| `GET /images/get`, `/images/{n}/get` | `saveImages(_ names:to: URL)` (write to a temp file, stream it, delete it) |
| `POST /images/load` | `loadImages(from: URL) async throws -> [LocalImage]` (plain or gzip) |
| `POST /images/create?fromSrc=` | `importImage(from:repo:tag:message:changes:platform:)` |
| `POST /images/prune` | `pruneImages(filters:) async throws -> ImagePruneResponse` |
`Engine.decodeRegistryAuth(headerValue)` parses `X-Registry-Auth`. `POST /build` runs through BuildKit (`Routes+System.swift`). Default platform is linux/arm64; `platform=linux/amd64` pulls amd64 and runs through Rosetta.

## Networks and volumes
Networks: `listNetworks(filters:)`, `inspectNetwork(_:)`, `createNetwork(_: NetworkCreateRequest) async throws -> (id, warning)`, `removeNetwork(_:)`, `connectNetwork(_:container:endpoint:)`, `disconnectNetwork(_:container:)`, `pruneNetworks(filters:)`. Built-ins: `bridge` 172.18.0.0/16 (gateway 172.18.0.1), `host`, `none`. User networks are carved from 172.19.0.0/16 upward, then 192.168.x.0/20. Container DNS resolves names and aliases via the gateway address.
Volumes: `createVolume(_:)`, `listVolumes(filters:)`, `inspectVolume(_:) async`, `removeVolume(_:force:) async`, `pruneVolumes(filters:all:) async`.
Bind sources must exist and be a directory or regular file; a file bind needs its folder approved with `noodle share add` (`Engine+Mounts.swift`).

## App/CLI helpers
`vmStatus() async -> VMStatus`, `wakeVM()`, `sleepVM()`, `updateVMSettings(cpus:memoryMiB:)` (next cold boot), `portMappings()`.
Container restart policies (`always`, `unless-stopped`, `on-failure[:n]`, backoff 100 ms doubling to 60 s) and `AutoRemove` run inside the engine. Published ports are host listeners (TCP and UDP) relayed over `relay_tcp` / `relay_udp`; bind conflicts raise `EngineError.portInUse` (500, "port is already allocated").

## Not implemented
Healthcheck execution (config stored, no probes), swarm/plugins, per-container log drivers (guest json log only), `docker commit --pause`, size fields (`SizeRw`).
