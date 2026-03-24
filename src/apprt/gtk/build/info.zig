const builtin = @import("builtin");

/// Base application ID for GResource paths. This intentionally stays as
/// "com.mitchellh.ghostty" even in cmux builds because it's the internal
/// GResource namespace compiled into the binary. The external app identity
/// (DBus, desktop files, icons) uses build_config.bundle_id instead.
/// See gresource.zig for how these paths are used in the resource XML.
pub const base_application_id = "com.mitchellh.ghostty";

/// GTK application ID
pub const application_id = switch (builtin.mode) {
    .Debug, .ReleaseSafe => base_application_id ++ "-debug",
    .ReleaseFast, .ReleaseSmall => base_application_id,
};

pub const resource_path = "/com/mitchellh/ghostty";

/// GTK object path
pub const object_path = switch (builtin.mode) {
    .Debug, .ReleaseSafe => resource_path ++ "_debug",
    .ReleaseFast, .ReleaseSmall => resource_path,
};
