const std = @import("std");

pub fn build(b: *std.Build) void {
    // Guest target: static aarch64 Linux, no libc. SHA-2 instructions are present on every
    // Apple silicon core the guest can run on, so std's Sha256 uses them.
    const guest_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .none,
        .cpu_features_add = std.Target.aarch64.featureSet(&.{ .sha2, .aes, .crc }),
    });

    // Untrusted-input parsers (tar headers, JSON control frames, DNS, wire framing) stay
    // ReleaseSafe even when the rest of the agent is ReleaseSmall (-Dparsers=small to opt out).
    const parser_mode: std.builtin.Optimize = if (b.option(bool, "parsers-small", "compile the parsers ReleaseSmall too") orelse false) .small else .safe;
    var parser_mods: [4]*std.Build.Module = undefined;
    const parser_names = [_][]const u8{ "tar", "json", "dnsmsg", "frame" };
    for (parser_names, 0..) |name, i| {
        parser_mods[i] = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = guest_target,
            .optimize = parser_mode,
            .strip = true,
            .unwind_tables = .none,
            .error_tracing = false,
            .single_threaded = true,
            .link_libc = false,
        });
    }

    const exe = b.addExecutable(.{
        .name = "init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = guest_target,
            .optimize = b.option(std.builtin.Optimize, "optimize", "guest optimize mode (default small = ReleaseSmall; safe = ReleaseSafe)") orelse .small,
            .strip = !(b.option(bool, "symbols", "keep symbols (size analysis)") orelse false),
            .unwind_tables = .none,
            .error_tracing = false,
            .single_threaded = true,
            .link_libc = false,
        }),
    });
    for (parser_names, 0..) |name, i| exe.root_module.addImport(name, parser_mods[i]);
    // Fault injection for Tests/supervisor-kill.sh only. The shipped agent never sets it.
    const options = b.addOptions();
    options.addOption(bool, "test_hooks", b.option(bool, "test-hooks", "compile fault-injection hooks (test builds only)") orelse false);
    // Stage stamps for the start path. Off in the shipped agent.
    options.addOption(bool, "start_timing", b.option(bool, "start-timing", "log per-stage timing of container start (measurement builds only)") orelse false);
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);

    // PID 1 of a Linux machine VM. Shares the agent's syscall, tar and DHCP code.
    const machine = b.addExecutable(.{
        .name = "machine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/machine.zig"),
            .target = guest_target,
            .optimize = .ReleaseSmall,
            .strip = true,
            .unwind_tables = .none,
            .error_tracing = false,
            .single_threaded = true,
            .link_libc = false,
        }),
    });
    for (parser_names, 0..) |name, i| machine.root_module.addImport(name, parser_mods[i]);
    machine.root_module.addOptions("build_options", options);
    b.installArtifact(machine);

    // Host-independent logic tests run natively (macOS) with `zig build test`.
    const test_step = b.step("test", "Run host-independent unit tests");
    inline for (.{ "src/tar.zig", "src/frame.zig", "src/json.zig", "src/dnsmsg.zig", "src/netlink.zig", "src/bpf.zig", "src/devcg.zig", "src/dnsredir.zig", "src/util.zig", "src/mount_path.zig", "src/sys.zig", "src/fspoke.zig", "src/meminfo.zig", "src/net.zig" }) |f| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(f),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    const layer_tests = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/layers.zig"), .target = b.graph.host, .optimize = .Debug }),
        .filters = &.{ "strict layer digest", "uncompressed stream hashes" },
    });
    layer_tests.root_module.addImport("tar", b.createModule(.{ .root_source_file = b.path("src/tar.zig") }));
    test_step.dependOn(&b.addRunArtifact(layer_tests).step);
    const tarfs_tests = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tarfs.zig"), .target = b.graph.host, .optimize = .Debug }),
        .filters = &.{"deeper than the limit"},
    });
    tarfs_tests.root_module.addImport("tar", b.createModule(.{ .root_source_file = b.path("src/tar.zig") }));
    test_step.dependOn(&b.addRunArtifact(tarfs_tests).step);
}
