const RGB = @import("../terminal/color.zig").RGB;

/// Darken a color by reducing its HSB brightness.
/// `amount` is a fraction: 0.0 = no change, 1.0 = fully black.
/// Matches macOS NSColor.darken(by:).
pub fn darken(c: RGB, amount: f64) RGB {
    const r_f: f64 = @as(f64, @floatFromInt(c.r)) / 255.0;
    const g_f: f64 = @as(f64, @floatFromInt(c.g)) / 255.0;
    const b_f: f64 = @as(f64, @floatFromInt(c.b)) / 255.0;

    const max_c = @max(r_f, @max(g_f, b_f));
    const min_c = @min(r_f, @min(g_f, b_f));
    const delta = max_c - min_c;

    // Hue
    var h: f64 = 0;
    if (delta > 0) {
        if (max_c == r_f) {
            h = @mod((g_f - b_f) / delta, 6.0);
        } else if (max_c == g_f) {
            h = (b_f - r_f) / delta + 2.0;
        } else {
            h = (r_f - g_f) / delta + 4.0;
        }
        h /= 6.0;
        if (h < 0) h += 1.0;
    }

    // Saturation
    const s: f64 = if (max_c == 0) 0 else delta / max_c;

    // Brightness: darken
    const brightness = @min(max_c * (1.0 - amount), 1.0);

    // HSB to RGB
    return hsbToRgb(h, s, brightness);
}

/// Returns true if the color is perceived as light.
pub fn isLight(c: RGB) bool {
    return c.perceivedLuminance() > 0.5;
}

fn hsbToRgb(h: f64, s: f64, b: f64) RGB {
    if (s == 0) {
        const v: u8 = @intFromFloat(@round(b * 255.0));
        return .{ .r = v, .g = v, .b = v };
    }

    const hh = h * 6.0;
    const sector: u32 = @intFromFloat(@floor(hh));
    const f = hh - @as(f64, @floatFromInt(sector));
    const p = b * (1.0 - s);
    const q = b * (1.0 - s * f);
    const t = b * (1.0 - s * (1.0 - f));

    const r_f, const g_f, const b_f = switch (sector % 6) {
        0 => .{ b, t, p },
        1 => .{ q, b, p },
        2 => .{ p, b, t },
        3 => .{ p, q, b },
        4 => .{ t, p, b },
        5 => .{ b, p, q },
        else => unreachable,
    };

    return .{
        .r = @intFromFloat(@round(r_f * 255.0)),
        .g = @intFromFloat(@round(g_f * 255.0)),
        .b = @intFromFloat(@round(b_f * 255.0)),
    };
}

test "darken black stays black" {
    const black = RGB{ .r = 0, .g = 0, .b = 0 };
    const result = darken(black, 0.5);
    try @import("std").testing.expectEqual(RGB{ .r = 0, .g = 0, .b = 0 }, result);
}

test "darken white by 1.0 gives black" {
    const white = RGB{ .r = 255, .g = 255, .b = 255 };
    const result = darken(white, 1.0);
    try @import("std").testing.expectEqual(RGB{ .r = 0, .g = 0, .b = 0 }, result);
}

test "darken by 0.0 is identity" {
    const c = RGB{ .r = 100, .g = 150, .b = 200 };
    const result = darken(c, 0.0);
    try @import("std").testing.expectEqual(c, result);
}

test "isLight for white" {
    try @import("std").testing.expect(isLight(RGB{ .r = 255, .g = 255, .b = 255 }));
}

test "isLight for black" {
    try @import("std").testing.expect(!isLight(RGB{ .r = 0, .g = 0, .b = 0 }));
}
