# Security checklist

Written for people deciding whether to run untrusted, automated or agent-generated workloads on Noodle. Status of each claim:

- **Code**: points at the source that implements it.
- **Test**: names a case that asserts it. "Ran" means the result is in the verification section at the end. Otherwise the case exists in the suite and was not run for this document.
- **Unverified**: no code or test backs it yet. Treat as not true.
- **Pending adversarial review**: concerns the privileged boundary. These claims stay unproven until an independent adversarial review covers them.

There is no formal threat model yet. This is a checklist, not a guarantee. Report problems privately as described in `SECURITY.md` (GitHub private vulnerability reporting).

## 1. What isolates a container

| Claim | Status | Evidence |
|---|---|---|
| Every ordinary container runs in a Linux guest VM, never on the Mac kernel | Code | `Sources/NoodleVM/VirtualMachineHost.swift` (Virtualization.framework), one agent as PID 1 in `guest/agent/src/main.zig` |
| Default capability set is Docker's 14 | Code | `default_caps` in `guest/agent/src/container.zig:98` |
| `--cap-drop ALL` leaves no effective capability; `--cap-add` adds one | Test | `t_sec_cap_drop_all`, `t_sec_cap_add` in `tests/e2e/security-and-limits.sh` |
| Default seccomp filter (`Seccomp: 2`) on ordinary containers | Code, test | `installSeccomp` in `container.zig:1019`; `t_sec_seccomp_default_and_unconfined` |
| `no-new-privileges` | Code, test | `container.zig:1112`; `t_sec_no_new_privileges` |
| `--read-only` root filesystem | Test | `t_sec_read_only_rootfs` |
| Default containers cannot mount | Test | `t_sec_default_no_mount` |
| Masked and read-only `/proc` and `/sys` paths | Code | `container.zig` "masked and read-only paths" section; no dedicated test found. Unverified |
| Unsafe sysctls are refused | Test | `t_sec_sysctl_reject_shared_and_unsafe` |
| cgroup resource limits | Code | `updateLimits` in `guest/agent/src/control.zig:159`; limits-under-pressure behaviour is Unverified |

## 2. The VM boundary

| Claim | Status | Evidence |
|---|---|---|
| The Linux service accepts vsock peers only when they are the host | Code | `acceptHostVsock` in `guest/agent/src/sys.zig:375` closes any other peer |
| The host listens on three vsock ports the guest dials: 1031 (ready, closed without reading, every VM), 1030 (SSH agent, main VM, after first use) and 1034 (Mac loopback forwarding, main VM, 8-byte header parsed as data). The privileged containers VM gets only 1031. Ordinary containers cannot open `AF_VSOCK` at all | Code, test | `VirtualMachineHost+Sockets.swift`, `VMController.setGuestListener` (main role only), `HostLoopback.parse`; `HostLoopbackTests`; protocol.md "Port 1034" |
| Privileged and `seccomp=unconfined` containers run in a second VM with no Rosetta share and a separate disk. It has no Mac folders while "Let Kubernetes use your shared folders" is off (the default for existing clusters; a new cluster turns it on) | Code, test | `t_priv_no_host_share`, `t_priv_negative_probes`, `t_k8s_shared_folders_off` |
| **With shared folders on, a privileged nested runtime can read and write the approved folders.** Any root process in the privileged containers VM (k3s, its pods, `docker run --privileged`) can mount the `host` virtiofs device itself and reach every approved folder given to any container there since the VM booted. Only approved folders are ever added, never all of `/Users`. The sharing change had a security review (fixes: Docker-socket relay refuses `/noodle/*`, canonical-path check at create, revoke on `share remove --restart`). What remains: the device policy guarding this VM is still not security reviewed | Code, test, sharing change reviewed (device policy **not reviewed**) | `VMSettings.workloadBindRefusal`, `Engine.validateWorkloadBinds`; `WorkloadRoutingTests`, `t_k8s_hostpath_approved_folder`, `t_k8s_hostpath_unapproved_sees_nothing`, `t_k8s_shared_folders_privileged_run` |
| Privileged containers cannot open the data disk, memory or vsock devices | Test, **pending adversarial review** | `t_priv_negative_probes`; eBPF device program in `guest/agent/src/devcg.zig` |
| `open_by_handle_at` is refused (EPERM) in privileged and unconfined containers, so `CAP_DAC_READ_SEARCH` cannot open data-disk files outside the mount root or reach `/sys/fs/cgroup/noodle` to detach the device policy. `name_to_handle_at` still works | Code, test | `bpf.buildHandleDeny`; `t_priv_negative_probes`, `t_priv_unconfined_keeps_only_the_handle_deny` |
| `core_pattern` and `uevent_helper` are the host-code-run paths a root `CAP_SYS_ADMIN` process could otherwise use to reach the agent's descriptors. The custom kernel config turns `COREDUMP` and `UEVENT_HELPER` off and `scripts/build-kernel.sh` fails if either resolves to `=y`. The app bundles the custom kernel built from this config; Apple's debug kernel is only a development fallback, and `scripts/stage-resources.sh` warns when it is staged | Config, **unverified on a running kernel** | `Resources/kernel/noodle.config`, `scripts/build-kernel.sh` |
| Vsock protection in the privileged containers VM comes from the agent's host-CID check and from the host listening only on port 1031 for that VM, not from the device policy | Code | `acceptHostVsock`, `VMController.setGuestListener` |
| Both VMs drop new connections that arrive on the uplink and are forwarded to a bridge, unless a DNAT rewrote them (published ports are dialed by the agent, not forwarded) | Code, test | `netlink.uplinkGuardBatch`, `net.setIpForward` |
| Guest replies are treated as data by the host parsers | Code, partially | `Sources/NoodleCore/GuestMessages.swift`, `Frames.swift`. No fuzzing was run. Unverified |
| The app bundles the custom guest kernel, not the Apple debug kernel | Code | `justfile` `kernel` recipe, `scripts/build-kernel.sh`, `scripts/stage-resources.sh`; `scripts/release.sh` refuses a bundled kernel that differs from `build/kernel/vmlinux` without matching source. No kernel CVE rebase policy is written |
| Kernel and agent are reproducible builds | Unverified | Not attempted |

## 3. What the host trusts

| Claim | Status | Evidence |
|---|---|---|
| The Docker API socket is mode 0600 inside a 0700 directory, so only the same user can use it | Code | `Sources/NoodleAPI/DockerServer.swift:40`, `Sources/noodled/NoodleDaemon.swift:20` |
| API access means full control of containers. There is no TLS or client certificate option | Code | no authentication layer exists in `Sources/NoodleAPI`. Anyone who can use the socket is the user |
| One daemon per data folder | Code | `flock` in `NoodleDaemon.swift:48` |
| Bind mounts of single files need an approved folder, because the VM can only share whole folders | Code | `Sources/NoodleEngine/Containers/Engine+Mounts.swift:40`; `noodle share add` |
| Bind mounts from the Mac are refused for privileged containers while shared folders are off; with it on, only canonical paths inside approved folders are accepted (`..`, symlinks, trailing slashes and case variants fail closed), checked at create and at every start | Test | `t_priv_no_host_share`, `t_k8s_shared_folders_privileged_run`, `t_k8s_shared_folders_off`, `WorkloadRoutingTests` |
| **Removing an approved folder does not end access already handed out.** With shared folders on, the privileged containers VM keeps the share until it stops and the k3s node keeps its bind until it is recreated. `noodle share remove <folder> --restart` (or "Restart Now" in Settings > Sharing) restarts that VM and recreates the node; without it, `noodle share remove` says plainly that access remains | Code | `Share.swift`, `k8sRevokeRemovedFolder`, `SharingSettings` |
| A container that binds the Docker socket (`-v /var/run/docker.sock:...`) gets the Docker API only. Its connections reach noodled through a separate socket (`run/guest.sock`), where every `/noodle/*` route and every model runner route (`/models`, `/engines`, `/logs`, `/exp`) answers 403, so it cannot change Noodle settings such as shared folders, or pull, delete or run the Mac's models | Code, test | `Router.relayRefusal`, `SSHAgent.serveDockerAPI`; `RelayRoutingTests`, `t_mount_docker_socket_refuses_noodle_routes` |
| Mac folders in an ordinary container are visible to that container with the user's rights | Test | `t_mount_bind_rw`, `t_mount_bind_readonly` |
| The Rosetta share exists only in the main VM | Code | `VirtualMachineHost.swift:37` (`enableRosetta = role == .main`) |
| Registry credentials come from the user's `~/.docker/config.json` (read only) or a credential helper, never stored by Noodle | Code | `Sources/NoodleImages/DockerConfig.swift` |
| Credentials are sent only over HTTPS | Code | `RegistryClient+Auth.swift:101` throws `credentials require HTTPS` |
| **Network access for models is off by default.** When the user turns on "Allow other devices to use my models" (`noodle model network on`), the model server binds `0.0.0.0` instead of loopback and keeps `--api-key-env --api-key-strict`: the runtime then answers every non-loopback request, including the web index and metrics pages, only with the key (Bearer, `x-api-key` or Basic), except `GET /health` and CORS preflight, which answer without it. The key is 64 hex characters, generated once, kept in `models/key` and `models/auth.header` (0600), passed to the runtime by environment (never argv) and replaced by `noodle model key --rotate` or Settings > Models > New Key, which restarts a running server. Traffic is plain HTTP on the local network, so the key and prompts are visible to anyone on that network segment. The runtime's own `--lan-share` and Bonjour are not used, because they only work without a key | Code, test | `MLXServeLaunch.arguments`, `ModelNetworkSetting`, `ModelAPIKey`; `ModelNetworkTests`; mlx-serve `auth.zig` (`apiKeyGateApplies`), `router.zig` auth gate; real 401/200/refused check in `docs/architecture/models.md` |
| Logs and diagnostics are scrubbed of tokens, registry credentials, secret-looking env values and home paths | Test, ran | `RedactorTests`, `DiagnosticLogsTests`; see section 7 |

## 4. Network egress

| Claim | Status | Evidence |
|---|---|---|
| Containers reach the internet through the VM's NAT attachment and nftables masquerade | Code | `VZNATNetworkDeviceAttachment` in `VirtualMachineHost.swift:121`; `nftMasq` in `guest/agent/src/net.zig:108` |
| Egress is open by default. There is no allow list and no per-container egress policy | Code | nothing in `net.zig` filters outbound traffic except `--internal` networks. Unverified for anything else |
| `docker network create --internal` blocks egress and external DNS, including after the container rewrites its default route | Test | `t_net_internal_blocks_egress` |
| Published ports bind `0.0.0.0` unless the user passes a host IP | Code | `PortForwarder.swift:33` |
| Privileged containers and ordinary containers sit on separate networks and cannot talk directly | Test | `t_priv_isolated_from_ordinary` |
| Containers on non-internal networks in the main VM, `--network host` containers and build `RUN` steps reach every Mac loopback TCP port through `host.docker.internal` and `host-gateway`, as 127.0.0.1 connections made by the Noodle engine. That includes services that trust loopback, such as another engine's Docker TCP API on 2375 or 2376 and Chrome DevTools on 9222, as on Docker Desktop | Code, test | `HostLoopbackRelay.swift`, `guest/agent/src/hostlo.zig`; `t_host_internal_reaches_mac_loopback` and the other `host-internal-loopback-*` cases in `tests/e2e/host-access.sh` |
| Local names listen on ports 80 and 443 without root and without touching system files (no hosts file, resolver or firewall edit). Each listener first binds 127.0.0.1 and ::1, which works only for root below port 1024. When that bind is refused, it binds 0.0.0.0 and [::] (IPv6 only) with `IP_BOUND_IF` and `IPV6_BOUND_IF` set to `lo0`. macOS does not use that setting to drop connections arriving on other interfaces, so a client on the LAN or in the VM can complete a TCP handshake. The barrier is the peer check: every accepted connection whose peer is outside 127.0.0.0/8, ::1 and ::ffff:127.0.0.0/104 is closed before a byte is read or TLS starts, so such a client gets no response. Containers that dial the Mac through the gateway address go through Noodle's loopback relay, which refuses Noodle's own ports. If another program already holds 80 or 443, the listener uses 10080 or 10443 with the same rules, so it never shadows a common published port such as 8080 | Code, test | `NameListener` (`openSocket`, `isLoopback(address:)`), `NameRouter.select`; `NameListenerBindTests`; `t_names_standard_ports_loopback_only_and_torn_down`, `t_names_port80_without_port_not_reachable_from_vm` in `tests/e2e/local-names-and-ssh-agent.sh` |
| Noodle's own loopback listeners (model server, Finder server, public-link fronts, local-name ports) are blocked by every Noodle engine owned by the user, whichever `NOODLE_HOME` owns them. Ports are claimed before they listen, in `~/Library/Application Support/Noodle/loopback-claims`, and rechecked after each connect | Code, test | `NoodleOwnedPorts`, `HostLoopback.targets`, `HostLoopbackRelay`; `HostLoopbackTests` (cross-daemon claims, recheck after connect); `t_host_internal_loopback_refuses_noodle_ports`, `t_host_internal_loopback_refuses_other_daemons_name_router` |
| `--internal` networks and the privileged containers VM get no loopback forwarding. A guest input guard drops every connection to the TCP forwarding port that no redirect rewrote, including from an internal network that shares the Mac's gateway address | Code, test | no redirect rule for internal bridges, `hostLoopbackGuardBatch` and the original-destination check in `hostlo.zig`, no 1034 listener for the privileged containers VM; `t_host_internal_loopback_blocked_on_internal_network` (with a Mac canary on 61034), `t_priv_host_internal_does_not_reach_mac_loopback`, the 1030 and 1034 probes in `t_priv_negative_probes` |
| A flood of forwarded TCP connections cannot stall the Linux service; forwarded connections close when the VM stops; forwarding processes hold no other descriptors | Code, test | 8 accepts per loop turn and `close_range` in `hostlo.zig`, `HostLoopbackRelay.closeAll`; `t_host_internal_loopback_flood_recovers`, `t_host_internal_loopback_relay_does_not_pin_logs`, `HostLoopbackTests.closeAllFreesSlotsWhenTheVMStops` |
| A `vm.json` that does not decode never turns TCP forwarding back on: noodled refuses to start | Code, test | `VMSettings.validateFile`, `Engine.start`; `HostLoopbackTests.undecodableSettingsFailClosed`, `t_host_internal_loopback_invalid_settings_refuse_start` |
| UDP to Mac loopback is not relayed | Code | only TCP matches the redirect rule (`hostLoopbackBatch` in `guest/agent/src/netlink.zig`) |
| `"host_loopback": false` in `vm.json` turns TCP forwarding off at the next daemon start: no 1034 listener and no guest redirect | Code, test | `VMSettings.hostLoopback`, `Engine+HostLoopback.swift`; `t_host_internal_loopback_off_setting_refuses` |

For hostile workloads today: use `--internal` networks, bind published ports to `127.0.0.1`, and do not mount Mac folders. `--internal` networks also cut Mac loopback access; `"host_loopback": false` cuts it for every container.

## 5. Update trust

| Claim | Status | Evidence |
|---|---|---|
| Image pulls verify the manifest digest against the requested digest and the registry's `Docker-Content-Digest`, and blobs against their descriptor digest | Code | `RegistryClient+Manifests.swift:22-25`, `BlobStore.adopt(file:expected:)` |
| Image signatures (cosign, notation) | Unverified | not implemented |
| Bundled tools are pinned with SHA-256 | Code | `scripts/fetch-tools.sh` |
| The app has a signed auto-update channel | Code, test; on from 26.11.3 | Ed25519-signed feed, SHA-256 and signing-team checks, staged swap with rollback; `swift test --filter Update`, `tests/update.sh`. The release key's public half is `NoodleUpdatePublicKey` in `app/Resources/Info.plist`; a real update between two published versions has not been exercised yet. and its public half is set |
| Release builds are Developer ID signed and notarized | Signed and notarized: ran | `scripts/release.sh build` signs with the hardened runtime and a secure timestamp, picking the keychain's Developer ID Application identity unless `NOODLE_SIGN_IDENTITY` overrides it; `scripts/release.sh verify` runs `codesign` and `spctl`. `scripts/release.sh notarize` submits the app and the DMG to Apple only when `NOODLE_CONFIRM_NOTARIZE=1` is set, and staples both. The 26.11.1 DMG is notarized and stapled |

## 6. Incident response

| Claim | Status | Evidence |
|---|---|---|
| Stop everything: `noodle stop` ends the daemon and its VMs | Code | `cmdStop` in `Sources/noodle/Commands/Daemon/DaemonLifecycle.swift:54` |
| Remove all state: `noodle uninstall --delete-data --yes` | Code | `Sources/noodle/Commands/Setup/SetupUninstall.swift` |
| Collect evidence without leaking secrets: `noodle logs`, `noodle diagnostics` | Test, ran | section 7 |
| Disclosure channel | Code | `SECURITY.md`: GitHub private vulnerability reporting |
| Crash reports and uploads | None | not implemented |

## 7. Diagnostics and consent

`noodle logs [engine|linux|privileged] [-n N] [--grep text] [-f] [--raw]` shows `noodled.log`, `vm.log` or `privileged/vm.log` from the data folder. Output is scrubbed unless `--raw` is given. On startup, Noodle moves an older `workload/` data directory to `privileged/`. If both directories exist, startup stops and asks you to move one aside; it preserves both. It reads files only; no process, timer or wakeup exists when it is unused.

`noodle diagnostics [-o file.tar.gz]` writes a `0600` archive to the current folder with `info.txt` (versions, OS, architecture, log sizes), `settings.json` and the last 2000 lines of each log, all scrubbed. It does not include container environments, image contents, volumes, `~/.docker` or the process environment.

The scrubber (`Sources/NoodleCore/Redactor.swift`) removes: authorization and bearer values, credentials inside URLs, JSON fields named like password, token, secret, auth or identitytoken, secret-looking `NAME=value` pairs and `--password`-style flags, common token shapes (GitHub, GitLab, npm, Slack, AWS, JWT, `sk-` keys), private key blocks, and home paths (the user's own becomes `~`, other users' names become `<user>`). It is pattern based. A secret in free text that matches none of these rules passes through, so read the archive before sharing it.

Consent design (a note, not built): there is no upload transport and no crash reporting. If an opt-in upload is ever added, it must be off by default, show the exact file list and sizes before each send, send nothing in the background, and keep the local-archive path working without it.

## Verification

- `swift test --filter "RedactorTests|DiagnosticLogsTests"`: 5 tests passed. Canaries (GitHub, Anthropic-style, AWS, Slack and npm tokens, a JWT, a registry password and identity token, a base64 auth value, URL credentials, env values, `--password` flags, a private key block, home paths) were planted in the three logs and `vm.json`, the archive was extracted, and every file was searched for each canary.
- Manual run of the built `noodle logs` and `noodle diagnostics` against a temporary data folder: the planted token and home path were redacted in both, and the archive search found none.
- No `docker` CLI case and no VM was run for this document. Every "Test" entry above that is not marked "ran" is an existing case in `tests/e2e/*.sh`.
