//! Build options, available at comptime. Used to configure features. This
//! will reproduce some of the fields from builtin and build_options just
//! so we can limit the amount of imports we need AND give us the ability
//! to shim logic and values into them later.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const assert = std.debug.assert;
const apprt = @import("apprt.zig");
const font = @import("font/main.zig");
const rendererpkg = @import("renderer.zig");
const BuildConfig = @import("build/Config.zig");

pub const ReleaseChannel = BuildConfig.ReleaseChannel;

/// The semantic version of this build.
pub const version = options.app_version;
pub const version_string = options.app_version_string;

/// The release channel for this build.
pub const release_channel = std.meta.stringToEnum(ReleaseChannel, @tagName(options.release_channel)).?;

/// The optimization mode as a string.
pub const mode_string = mode: {
    const m = @tagName(builtin.mode);
    if (std.mem.lastIndexOfScalar(u8, m, '.')) |i| break :mode m[i..];
    break :mode m;
};

/// The artifact we're producing. This can be used to determine if we're
/// building a standalone exe, an embedded lib, etc.
pub const artifact = Artifact.detect();

/// Our build configuration. We re-export a lot of these back at the
/// top-level so its a bit cleaner to use throughout the code. See the doc
/// comments in BuildConfig for details on each.
const config = BuildConfig.fromOptions();
pub const exe_entrypoint = config.exe_entrypoint;
pub const flatpak = options.flatpak;
pub const snap = options.snap;
pub const app_runtime: apprt.Runtime = config.app_runtime;
pub const font_backend: font.Backend = config.font_backend;
pub const renderer: rendererpkg.Backend = config.renderer;
pub const i18n: bool = config.i18n;

/// Whether this is a cmux variant build.
pub const cmux: bool = options.cmux;

/// The bundle ID for the app.
pub const bundle_id: [:0]const u8 = if (options.cmux) "com.cmuxterm.app" else "com.mitchellh.ghostty";

/// Display name for the application.
pub const app_name: [:0]const u8 = if (options.cmux) "cmux" else "Ghostty";

/// The subdirectory name under share/ for resources.
pub const resource_dir_name: [:0]const u8 = if (options.cmux) "cmux" else "ghostty";

/// The environment variable used to locate the resources directory.
/// This stays as GHOSTTY_RESOURCES_DIR even in cmux mode because the
/// resources (terminfo, shell integration, themes) are Ghostty's terminal
/// engine resources. The Mac version uses this same convention.
pub const resources_env_var: [:0]const u8 = "GHOSTTY_RESOURCES_DIR";

/// GTK application ID (includes debug suffix).
pub const application_id: [:0]const u8 = bundle_id ++ switch (builtin.mode) {
    .Debug, .ReleaseSafe => "-debug",
    .ReleaseFast, .ReleaseSmall => "",
};

/// DBus object path (includes debug suffix).
pub const object_path: [:0]const u8 = (if (options.cmux) "/com/cmuxterm/app" else "/com/mitchellh/ghostty") ++ switch (builtin.mode) {
    .Debug, .ReleaseSafe => "_debug",
    .ReleaseFast, .ReleaseSmall => "",
};

/// True if we should have "slow" runtime safety checks. The initial motivation
/// for this was terminal page/pagelist integrity checks. These were VERY
/// slow but very thorough. But they made it so slow that the terminal couldn't
/// be used for real work. We'd love to have an option to run a build with
/// safety checks that could be used for real work. This lets us do that.
pub const slow_runtime_safety = std.debug.runtime_safety and switch (builtin.mode) {
    .Debug => true,
    .ReleaseSafe,
    .ReleaseSmall,
    .ReleaseFast,
    => false,
};

pub const Artifact = enum {
    /// Standalone executable
    exe,

    /// Embeddable library
    lib,

    /// The WASM-targeted module.
    wasm_module,

    pub fn detect() Artifact {
        if (builtin.target.cpu.arch.isWasm()) {
            assert(builtin.output_mode == .Obj);
            assert(builtin.link_mode == .Static);
            return .wasm_module;
        }

        return switch (builtin.output_mode) {
            .Exe => .exe,
            .Lib => .lib,
            else => {
                @compileLog(builtin.output_mode);
                @compileError("unsupported artifact output mode");
            },
        };
    }
};

/// True if runtime safety checks are enabled.
pub const is_debug = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};
