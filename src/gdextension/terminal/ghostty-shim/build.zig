const std = @import("std");

/// Build the minerva-vt shim library.
///
/// We construct the ghostty-vt module directly from ghostty's source,
/// bypassing ghostty's build.zig entirely. This avoids an issue where
/// ghostty's build.zig tries to create an XCFramework on macOS hosts
/// (requiring full Xcode/iOS SDK), even when only lib-vt is needed.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ghostty_root = b.path("../../../../vendor/ghostty");

    // ── Build options ───────────────────────────────────────────────
    const terminal_options = b.addOptions();
    terminal_options.addOption(enum { ghostty, lib }, "artifact", .lib);
    terminal_options.addOption(bool, "c_abi", false);
    terminal_options.addOption(bool, "oniguruma", false);
    terminal_options.addOption(bool, "simd", false);
    terminal_options.addOption(bool, "slow_runtime_safety", false);
    terminal_options.addOption(bool, "kitty_graphics", false);
    terminal_options.addOption(bool, "tmux_control_mode", false);

    const build_options = b.addOptions();
    build_options.addOption(bool, "sentry", false);
    build_options.addOption(bool, "simd", false);
    build_options.addOption(bool, "i18n", false);

    // ── uucode dependency (grapheme break tables) ───────────────────
    const uucode = b.dependency("uucode", .{
        .target = b.graph.host,
        .build_config_path = ghostty_root.path(b, "src/build/uucode_config.zig"),
    });
    const uucode_tables = uucode.namedLazyPath("tables.zig");

    // ── Unicode props table generator ───────────────────────────────
    // We replicate UnicodeTables.init: build props-unigen and
    // symbols-unigen executables, run them, capture generated .zig files.
    const props_exe = b.addExecutable(.{
        .name = "props-unigen",
        .root_module = b.createModule(.{
            .root_source_file = ghostty_root.path(b, "src/unicode/props_uucode.zig"),
            .target = b.graph.host,
        }),
        .use_llvm = true,
    });
    props_exe.root_module.addImport("uucode", uucode.module("uucode"));

    const symbols_exe = b.addExecutable(.{
        .name = "symbols-unigen",
        .root_module = b.createModule(.{
            .root_source_file = ghostty_root.path(b, "src/unicode/symbols_uucode.zig"),
            .target = b.graph.host,
        }),
        .use_llvm = true,
    });
    symbols_exe.root_module.addImport("uucode", uucode.module("uucode"));

    const props_run = b.addRunArtifact(props_exe);
    const symbols_run = b.addRunArtifact(symbols_exe);
    // The unigen executables write generated Zig source to stdout
    const wf = b.addWriteFiles();
    const props_output = wf.addCopyFile(props_run.captureStdOut(), "props.zig");
    const symbols_output = wf.addCopyFile(symbols_run.captureStdOut(), "symbols.zig");

    // ── ghostty-vt module ──────────────────────────────────────────
    const vt_mod = b.addModule("ghostty-vt", .{
        .root_source_file = ghostty_root.path(b, "src/lib_vt.zig"),
        .target = target,
        .optimize = optimize,
    });
    vt_mod.addOptions("terminal_options", terminal_options);
    vt_mod.addOptions("build_options", build_options);

    // Wire up unicode tables as anonymous imports (matching UnicodeTables.addModuleImport)
    vt_mod.addAnonymousImport("unicode_tables", .{ .root_source_file = props_output });
    vt_mod.addAnonymousImport("symbols_tables", .{ .root_source_file = symbols_output });

    // Wire up uucode module (matching SharedDeps.addUucode)
    const uucode_target = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .tables_path = uucode_tables,
        .build_config_path = ghostty_root.path(b, "src/build/uucode_config.zig"),
    });
    vt_mod.addImport("uucode", uucode_target.module("uucode"));

    // ── Shim module ────────────────────────────────────────────────
    const shim_mod = b.createModule(.{
        .root_source_file = b.path("src/shim.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    shim_mod.addImport("ghostty-vt", vt_mod);

    // ── Shared library ─────────────────────────────────────────────
    const lib = b.addLibrary(.{
        .name = "minerva-vt",
        .linkage = .dynamic,
        .root_module = shim_mod,
    });
    b.installArtifact(lib);
    lib.installHeader(b.path("src/minerva_vt.h"), "minerva_vt.h");

    // ── Test step ──────────────────────────────────────────────────
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = shim_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
