/// Programmatic ARGB icon rendering for the StatusNotifierItem.
///
/// Generates a 22x22 (or other size) ARGB32 pixmap suitable for the SNI
/// `IconPixmap` property. The icon contains a right-pointing arrow glyph
/// (matching the macOS cmux center-mark) and an optional notification badge.
///
/// The SNI spec requires ARGB pixels in **network byte order** (big-endian).
const std = @import("std");
const badge = @import("../notification/badge.zig");

/// Render the cmux tray icon into `buf` as ARGB32 pixels in network byte order.
///
/// Returns the filled slice (length = size * size * 4 bytes).
/// `buf` must be at least `size * size * 4` bytes.
pub fn renderIcon(buf: []u8, size: u32, unread_count: u32) []const u8 {
    const total = size * size * 4;
    std.debug.assert(buf.len >= total);

    // Clear to fully transparent.
    @memset(buf[0..total], 0);

    // Draw the arrow glyph.
    drawGlyph(buf, size);

    // Draw the notification badge if needed.
    if (unread_count > 0) {
        drawBadge(buf, size, unread_count);
    }

    return buf[0..total];
}

/// Draw the cmux right-pointing arrow glyph.
///
/// Ports the macOS `MenuBarIconRenderer.drawGlyph` path:
///   move(384, 255) → line(753, 511.5) → line(384, 768)
///   → line(384, 654) → line(582.692, 511.5) → line(384, 369) → close
///
/// The glyph is positioned in the left portion of the icon to leave room
/// for the badge in the top-right corner.
fn drawGlyph(buf: []u8, size: u32) void {
    // Source coordinates from the SVG artwork.
    const src_min_x: f64 = 384.0;
    const src_min_y: f64 = 255.0;
    const src_w: f64 = 369.0;
    const src_h: f64 = 513.0;

    // Glyph rect within the icon (matching Mac's proportional placement).
    // On Mac: icon=18x18, glyph at (1.2, 1.5, 11.6x15.0).
    // Scale proportionally for our icon size.
    const s = @as(f64, @floatFromInt(size));
    const glyph_x = s * (1.2 / 18.0);
    const glyph_y = s * (1.5 / 18.0);
    const glyph_w = s * (11.6 / 18.0);
    const glyph_h = s * (15.0 / 18.0);

    // Map SVG source coords to pixel coords (top-down buffer, no Y-flip).
    const Pt = struct { x: f64, y: f64 };
    const mapTD = struct {
        fn f(sx: f64, sy: f64, gx: f64, gy: f64, gw: f64, gh: f64) Pt {
            const nx = (sx - src_min_x) / src_w;
            const ny = (sy - src_min_y) / src_h;
            return .{
                .x = gx + nx * gw,
                .y = gy + ny * gh,
            };
        }
    }.f;

    // The 6 vertices of the arrow polygon.
    const verts = [_]Pt{
        mapTD(384.0, 255.0, glyph_x, glyph_y, glyph_w, glyph_h),
        mapTD(753.0, 511.5, glyph_x, glyph_y, glyph_w, glyph_h),
        mapTD(384.0, 768.0, glyph_x, glyph_y, glyph_w, glyph_h),
        mapTD(384.0, 654.0, glyph_x, glyph_y, glyph_w, glyph_h),
        mapTD(582.692, 511.5, glyph_x, glyph_y, glyph_w, glyph_h),
        mapTD(384.0, 369.0, glyph_x, glyph_y, glyph_w, glyph_h),
    };

    // Rasterize the polygon using scanline fill.
    // Color: opaque white (template icon — tray will colorize it).
    // ARGB big-endian: A=0xFF, R=0xFF, G=0xFF, B=0xFF
    const pixel = argbBE(0xFF, 0xFF, 0xFF, 0xFF);

    var y: u32 = 0;
    while (y < size) : (y += 1) {
        const fy: f64 = @as(f64, @floatFromInt(y)) + 0.5;

        // Find all X intersections of scanline with polygon edges.
        var intersections: [12]f64 = undefined;
        var n_intersections: u32 = 0;

        for (0..verts.len) |i| {
            const j = (i + 1) % verts.len;
            const y0 = verts[i].y;
            const y1 = verts[j].y;

            if ((y0 <= fy and y1 > fy) or (y1 <= fy and y0 > fy)) {
                const t = (fy - y0) / (y1 - y0);
                const ix = verts[i].x + t * (verts[j].x - verts[i].x);
                if (n_intersections < intersections.len) {
                    intersections[n_intersections] = ix;
                    n_intersections += 1;
                }
            }
        }

        // Sort intersections.
        sortF64(intersections[0..n_intersections]);

        // Fill between pairs.
        var k: u32 = 0;
        while (k + 1 < n_intersections) : (k += 2) {
            const x_start = @as(u32, @intFromFloat(@max(0.0, @ceil(intersections[k]))));
            const x_end_f = @min(@as(f64, @floatFromInt(size)), @floor(intersections[k + 1]));
            const x_end: u32 = if (x_end_f < 0.0) 0 else @intFromFloat(x_end_f);

            var x: u32 = x_start;
            while (x < x_end) : (x += 1) {
                setPixel(buf, size, x, y, pixel);
            }
        }
    }
}

/// Draw a notification count badge in the top-right corner.
fn drawBadge(buf: []u8, size: u32, unread_count: u32) void {
    var text_buf: [4]u8 = undefined;
    const text = badge.menuBarBadgeText(&text_buf, unread_count) orelse return;
    const text_len = text.len;

    const s = @as(f64, @floatFromInt(size));

    // Badge circle: positioned in top-right quadrant.
    // Radius scales with icon size.
    const badge_radius = s * 0.25;
    const badge_cx = s - badge_radius - 0.5;
    const badge_cy = badge_radius + 0.5;

    // Badge background: system blue (ARGB).
    const blue_pixel = argbBE(0xFF, 0x30, 0x7A, 0xF1);

    // Draw filled circle.
    const r2 = badge_radius * badge_radius;
    var y: u32 = 0;
    while (y < size) : (y += 1) {
        const fy = @as(f64, @floatFromInt(y)) + 0.5;
        const dy = fy - badge_cy;
        var x: u32 = 0;
        while (x < size) : (x += 1) {
            const fx = @as(f64, @floatFromInt(x)) + 0.5;
            const dx = fx - badge_cx;
            if (dx * dx + dy * dy <= r2) {
                setPixel(buf, size, x, y, blue_pixel);
            }
        }
    }

    // Draw the text (simple bitmap digits).
    // For a 22px icon, badge radius ~5.5px, so we use a tiny 3x5 font.
    const digit_w: u32 = 3;
    const digit_h: u32 = 5;

    // Total text width in pixels.
    const total_w = @as(u32, @intCast(text_len)) * digit_w + (@as(u32, @intCast(text_len)) - 1); // 1px gap between chars
    const text_x = @as(u32, @intFromFloat(badge_cx)) -| (total_w / 2);
    const text_y = @as(u32, @intFromFloat(badge_cy)) -| (digit_h / 2);

    const white_pixel = argbBE(0xFF, 0xFF, 0xFF, 0xFF);

    for (text, 0..) |ch, ci| {
        const glyph = digitGlyph(ch);
        const char_x = text_x + @as(u32, @intCast(ci)) * (digit_w + 1);
        for (0..digit_h) |row| {
            for (0..digit_w) |col| {
                if (glyph[row] & (@as(u8, 1) << @intCast(digit_w - 1 - col)) != 0) {
                    const px = char_x + @as(u32, @intCast(col));
                    const py = text_y + @as(u32, @intCast(row));
                    if (px < size and py < size) {
                        setPixel(buf, size, px, py, white_pixel);
                    }
                }
            }
        }
    }
}

/// Set a single pixel in the ARGB buffer (network byte order).
fn setPixel(buf: []u8, stride: u32, x: u32, y: u32, pixel: [4]u8) void {
    const offset = (y * stride + x) * 4;
    buf[offset + 0] = pixel[0];
    buf[offset + 1] = pixel[1];
    buf[offset + 2] = pixel[2];
    buf[offset + 3] = pixel[3];
}

/// Encode ARGB as 4 bytes in big-endian (network) byte order.
fn argbBE(a: u8, r: u8, g: u8, b: u8) [4]u8 {
    return .{ a, r, g, b };
}

/// Simple insertion sort for a small array of f64.
fn sortF64(arr: []f64) void {
    if (arr.len <= 1) return;
    for (1..arr.len) |i| {
        const key = arr[i];
        var j: usize = i;
        while (j > 0 and arr[j - 1] > key) {
            arr[j] = arr[j - 1];
            j -= 1;
        }
        arr[j] = key;
    }
}

/// 3x5 bitmap font for digits 0-9 and '+'.
/// Each entry is 5 rows, each row is a bitmask of 3 columns (MSB = left).
fn digitGlyph(ch: u8) [5]u8 {
    return switch (ch) {
        '0' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        '1' => .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        '2' => .{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        '3' => .{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        '4' => .{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        '5' => .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        '6' => .{ 0b111, 0b100, 0b111, 0b101, 0b111 },
        '7' => .{ 0b111, 0b001, 0b001, 0b001, 0b001 },
        '8' => .{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        '9' => .{ 0b111, 0b101, 0b111, 0b001, 0b111 },
        '+' => .{ 0b000, 0b010, 0b111, 0b010, 0b000 },
        else => .{ 0, 0, 0, 0, 0 },
    };
}

// ══════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════

const testing = std.testing;

test "renderIcon returns correct size" {
    var buf: [22 * 22 * 4]u8 = undefined;
    const result = renderIcon(&buf, 22, 0);
    try testing.expectEqual(@as(usize, 22 * 22 * 4), result.len);
}

test "renderIcon with zero unread has no badge pixels" {
    var buf: [22 * 22 * 4]u8 = undefined;
    _ = renderIcon(&buf, 22, 0);

    // Badge color is 0x307AF1 — check no pixel has that RGB.
    var found_blue = false;
    var i: usize = 0;
    while (i < buf.len) : (i += 4) {
        if (buf[i + 1] == 0x30 and buf[i + 2] == 0x7A and buf[i + 3] == 0xF1) {
            found_blue = true;
            break;
        }
    }
    try testing.expect(!found_blue);
}

test "renderIcon with unread has badge pixels" {
    var buf: [22 * 22 * 4]u8 = undefined;
    _ = renderIcon(&buf, 22, 3);

    // Should have blue badge pixels.
    var found_blue = false;
    var i: usize = 0;
    while (i < buf.len) : (i += 4) {
        if (buf[i + 1] == 0x30 and buf[i + 2] == 0x7A and buf[i + 3] == 0xF1) {
            found_blue = true;
            break;
        }
    }
    try testing.expect(found_blue);
}

test "renderIcon has glyph pixels" {
    var buf: [22 * 22 * 4]u8 = undefined;
    _ = renderIcon(&buf, 22, 0);

    // Should have white (glyph) pixels.
    var found_white = false;
    var i: usize = 0;
    while (i < buf.len) : (i += 4) {
        if (buf[i] == 0xFF and buf[i + 1] == 0xFF and buf[i + 2] == 0xFF and buf[i + 3] == 0xFF) {
            found_white = true;
            break;
        }
    }
    try testing.expect(found_white);
}

test "digitGlyph returns non-empty for valid digits" {
    for ("0123456789+") |ch| {
        const g = digitGlyph(ch);
        var any_set = false;
        for (g) |row| {
            if (row != 0) any_set = true;
        }
        try testing.expect(any_set);
    }
}
