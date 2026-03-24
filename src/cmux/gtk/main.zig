//! cmux GTK integration module.
//!
//! Provides the cmux-specific GTK UI: a window with a sidebar workspace list
//! and a stacked content area showing terminal surfaces.

const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../config.zig");
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const Application = @import("../../apprt/gtk/class/application.zig").Application;

pub const CmuxWindow = @import("window.zig").CmuxWindow;
pub const bridge = @import("bridge.zig");

/// Entry point called from Application.newWindow when build_config.cmux is true.
/// Creates a CmuxWindow instead of a standard Ghostty Window.
pub fn newCmuxWindow(
    app: *Application,
    parent: ?*CoreSurface,
    overrides: anytype,
) !void {
    _ = parent;
    _ = overrides;

    const win = CmuxWindow.new(app);

    // Bind Application config → CmuxWindow config
    _ = gobject.Object.bindProperty(
        app.as(gobject.Object),
        "config",
        win.as(gobject.Object),
        "config",
        .{},
    );

    // Present the window
    gtk.Window.present(win.as(gtk.Window));
}
