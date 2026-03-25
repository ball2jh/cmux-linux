//! Markdown-to-HTML converter with embedded CSS theme.
//!
//! Converts a subset of CommonMark to a complete HTML document
//! suitable for loading into a WebKitGTK WebView. The CSS theme
//! matches the Mac version's cmuxMarkdownTheme.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Render markdown text to a complete HTML document string.
/// Caller owns the returned slice.
pub fn renderToHtml(allocator: Allocator, markdown: []const u8, is_dark: bool) ![:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Write HTML header with embedded CSS
    try out.appendSlice(allocator, "<!DOCTYPE html><html><head><meta charset=\"utf-8\">");
    try out.appendSlice(allocator, "<style>");
    try out.appendSlice(allocator, if (is_dark) css_dark else css_light);
    try out.appendSlice(allocator, "</style></head><body>");

    // Parse and convert markdown
    var in_code_block = false;
    var in_list = false;
    var in_ordered_list = false;
    var in_table = false;
    var in_blockquote = false;
    var in_paragraph = false;

    var iter = LineIterator{ .data = markdown };
    while (iter.next()) |line| {
        // Fenced code block toggle
        if (std.mem.startsWith(u8, line, "```")) {
            if (in_paragraph) { try out.appendSlice(allocator, "</p>"); in_paragraph = false; }
            if (in_code_block) {
                try out.appendSlice(allocator, "</code></pre>");
                in_code_block = false;
            } else {
                closeOpenBlocks(allocator, &out, &in_list, &in_ordered_list, &in_table, &in_blockquote);
                try out.appendSlice(allocator, "<pre><code>");
                in_code_block = true;
            }
            continue;
        }

        if (in_code_block) {
            try appendEscaped(allocator, &out, line);
            try out.append(allocator, '\n');
            continue;
        }

        const trimmed = std.mem.trimLeft(u8, line, " \t");

        // Empty line — close open paragraph
        if (trimmed.len == 0) {
            if (in_paragraph) { try out.appendSlice(allocator, "</p>"); in_paragraph = false; }
            if (in_blockquote) { try out.appendSlice(allocator, "</blockquote>"); in_blockquote = false; }
            continue;
        }

        // Horizontal rule
        if (isHorizontalRule(trimmed)) {
            if (in_paragraph) { try out.appendSlice(allocator, "</p>"); in_paragraph = false; }
            closeOpenBlocks(allocator, &out, &in_list, &in_ordered_list, &in_table, &in_blockquote);
            try out.appendSlice(allocator, "<hr>");
            continue;
        }

        // Headings
        if (parseHeading(trimmed)) |h| {
            if (in_paragraph) { try out.appendSlice(allocator, "</p>"); in_paragraph = false; }
            closeOpenBlocks(allocator, &out, &in_list, &in_ordered_list, &in_table, &in_blockquote);
            var tag_buf: [4]u8 = undefined;
            const tag = std.fmt.bufPrint(&tag_buf, "h{d}", .{h.level}) catch "h1";
            try out.appendSlice(allocator, "<");
            try out.appendSlice(allocator, tag);
            try out.appendSlice(allocator, ">");
            try appendInline(allocator, &out, h.content);
            try out.appendSlice(allocator, "</");
            try out.appendSlice(allocator, tag);
            try out.appendSlice(allocator, ">");
            continue;
        }

        // Blockquote
        if (trimmed.len > 1 and trimmed[0] == '>') {
            if (in_paragraph) { try out.appendSlice(allocator, "</p>"); in_paragraph = false; }
            if (!in_blockquote) {
                closeOpenBlocks(allocator, &out, &in_list, &in_ordered_list, &in_table, &in_blockquote);
                try out.appendSlice(allocator, "<blockquote>");
                in_blockquote = true;
            }
            const content = std.mem.trimLeft(u8, trimmed[1..], " ");
            try out.appendSlice(allocator, "<p>");
            try appendInline(allocator, &out, content);
            try out.appendSlice(allocator, "</p>");
            continue;
        }

        if (in_blockquote) {
            try out.appendSlice(allocator, "</blockquote>");
            in_blockquote = false;
        }

        // Table row
        if (trimmed.len > 0 and trimmed[0] == '|') {
            if (in_paragraph) { try out.appendSlice(allocator, "</p>"); in_paragraph = false; }
            // Check for separator row (|---|---|)
            if (isTableSeparator(trimmed)) continue;
            if (!in_table) {
                closeOpenBlocks(allocator, &out, &in_list, &in_ordered_list, &in_table, &in_blockquote);
                try out.appendSlice(allocator, "<table><tbody>");
                in_table = true;
            }
            try appendTableRow(allocator, &out, trimmed);
            continue;
        }

        if (in_table) {
            try out.appendSlice(allocator, "</tbody></table>");
            in_table = false;
        }

        // Unordered list item
        if ((trimmed.len > 2 and (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and trimmed[1] == ' ')) {
            if (in_paragraph) { try out.appendSlice(allocator, "</p>"); in_paragraph = false; }
            if (in_ordered_list) { try out.appendSlice(allocator, "</ol>"); in_ordered_list = false; }
            if (!in_list) {
                try out.appendSlice(allocator, "<ul>");
                in_list = true;
            }
            try out.appendSlice(allocator, "<li>");
            try appendInline(allocator, &out, trimmed[2..]);
            try out.appendSlice(allocator, "</li>");
            continue;
        }

        // Ordered list item
        if (parseOrderedListItem(trimmed)) |content| {
            if (in_paragraph) { try out.appendSlice(allocator, "</p>"); in_paragraph = false; }
            if (in_list) { try out.appendSlice(allocator, "</ul>"); in_list = false; }
            if (!in_ordered_list) {
                try out.appendSlice(allocator, "<ol>");
                in_ordered_list = true;
            }
            try out.appendSlice(allocator, "<li>");
            try appendInline(allocator, &out, content);
            try out.appendSlice(allocator, "</li>");
            continue;
        }

        // Close lists if this is a non-list line
        if (in_list) { try out.appendSlice(allocator, "</ul>"); in_list = false; }
        if (in_ordered_list) { try out.appendSlice(allocator, "</ol>"); in_ordered_list = false; }

        // Paragraph text
        if (!in_paragraph) {
            try out.appendSlice(allocator, "<p>");
            in_paragraph = true;
        } else {
            try out.appendSlice(allocator, " ");
        }
        try appendInline(allocator, &out, trimmed);
    }

    // Close any remaining open blocks
    if (in_code_block) try out.appendSlice(allocator, "</code></pre>");
    if (in_paragraph) try out.appendSlice(allocator, "</p>");
    if (in_list) try out.appendSlice(allocator, "</ul>");
    if (in_ordered_list) try out.appendSlice(allocator, "</ol>");
    if (in_table) try out.appendSlice(allocator, "</tbody></table>");
    if (in_blockquote) try out.appendSlice(allocator, "</blockquote>");

    try out.appendSlice(allocator, "</body></html>");
    try out.append(allocator, 0);

    const slice = try out.toOwnedSlice(allocator);
    return slice[0 .. slice.len - 1 :0];
}

// ── Inline formatting ────────────────────────────────────────

fn appendInline(allocator: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        // Bold (**text**)
        if (c == '*' and i + 1 < text.len and text[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |end| {
                try out.appendSlice(allocator, "<strong>");
                try appendEscaped(allocator, out, text[i + 2 .. end]);
                try out.appendSlice(allocator, "</strong>");
                i = end + 2;
                continue;
            }
        }

        // Italic (*text*)
        if (c == '*' and i + 1 < text.len and text[i + 1] != '*') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '*')) |end| {
                try out.appendSlice(allocator, "<em>");
                try appendEscaped(allocator, out, text[i + 1 .. end]);
                try out.appendSlice(allocator, "</em>");
                i = end + 1;
                continue;
            }
        }

        // Inline code (`text`)
        if (c == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |end| {
                try out.appendSlice(allocator, "<code>");
                try appendEscaped(allocator, out, text[i + 1 .. end]);
                try out.appendSlice(allocator, "</code>");
                i = end + 1;
                continue;
            }
        }

        // Link [text](url)
        if (c == '[') {
            if (parseLink(text[i..])) |link| {
                try out.appendSlice(allocator, "<a href=\"");
                try appendEscaped(allocator, out, link.url);
                try out.appendSlice(allocator, "\">");
                try appendEscaped(allocator, out, link.label);
                try out.appendSlice(allocator, "</a>");
                i += link.total_len;
                continue;
            }
        }

        // HTML escaping for normal characters
        switch (c) {
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '&' => try out.appendSlice(allocator, "&amp;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            else => try out.append(allocator, c),
        }
        i += 1;
    }
}

fn appendEscaped(allocator: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '&' => try out.appendSlice(allocator, "&amp;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            else => try out.append(allocator, c),
        }
    }
}

// ── Block element parsers ────────────────────────────────────

const Heading = struct { level: u8, content: []const u8 };

fn parseHeading(line: []const u8) ?Heading {
    var level: u8 = 0;
    while (level < line.len and level < 6 and line[level] == '#') level += 1;
    if (level == 0) return null;
    if (level >= line.len or line[level] != ' ') return null;
    return .{ .level = level, .content = std.mem.trimRight(u8, line[level + 1 ..], " \t#") };
}

fn isHorizontalRule(line: []const u8) bool {
    var count: usize = 0;
    var ch: ?u8 = null;
    for (line) |c| {
        if (c == ' ' or c == '\t') continue;
        if (c != '-' and c != '*' and c != '_') return false;
        if (ch == null) ch = c else if (c != ch.?) return false;
        count += 1;
    }
    return count >= 3;
}

fn isTableSeparator(line: []const u8) bool {
    for (line) |c| {
        if (c != '|' and c != '-' and c != ':' and c != ' ' and c != '\t') return false;
    }
    return std.mem.indexOf(u8, line, "---") != null;
}

fn appendTableRow(allocator: Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    try out.appendSlice(allocator, "<tr>");
    // Split by | and add cells, skipping leading/trailing empty
    var start: usize = if (line.len > 0 and line[0] == '|') 1 else 0;
    while (start < line.len) {
        const end = std.mem.indexOfScalarPos(u8, line, start, '|') orelse line.len;
        const cell = std.mem.trim(u8, line[start..end], " \t");
        try out.appendSlice(allocator, "<td>");
        try appendInline(allocator, out, cell);
        try out.appendSlice(allocator, "</td>");
        start = end + 1;
    }
    try out.appendSlice(allocator, "</tr>");
}

fn parseOrderedListItem(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i == 0 or i >= line.len) return null;
    if (line[i] != '.' or i + 1 >= line.len or line[i + 1] != ' ') return null;
    return line[i + 2 ..];
}

const LinkParts = struct { label: []const u8, url: []const u8, total_len: usize };

fn parseLink(text: []const u8) ?LinkParts {
    if (text.len < 4 or text[0] != '[') return null;
    const close_bracket = std.mem.indexOfScalar(u8, text, ']') orelse return null;
    if (close_bracket + 1 >= text.len or text[close_bracket + 1] != '(') return null;
    const close_paren = std.mem.indexOfScalarPos(u8, text, close_bracket + 2, ')') orelse return null;
    return .{
        .label = text[1..close_bracket],
        .url = text[close_bracket + 2 .. close_paren],
        .total_len = close_paren + 1,
    };
}

fn closeOpenBlocks(allocator: Allocator, out: *std.ArrayList(u8), in_list: *bool, in_ordered_list: *bool, in_table: *bool, in_blockquote: *bool) void {
    if (in_list.*) { out.appendSlice(allocator, "</ul>") catch {}; in_list.* = false; }
    if (in_ordered_list.*) { out.appendSlice(allocator, "</ol>") catch {}; in_ordered_list.* = false; }
    if (in_table.*) { out.appendSlice(allocator, "</tbody></table>") catch {}; in_table.* = false; }
    if (in_blockquote.*) { out.appendSlice(allocator, "</blockquote>") catch {}; in_blockquote.* = false; }
}

// ── Line iterator ────────────────────────────────────────────

const LineIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *LineIterator) ?[]const u8 {
        if (self.pos >= self.data.len) return null;
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '\n') self.pos += 1;
        const end = self.pos;
        if (self.pos < self.data.len) self.pos += 1; // skip \n
        // Trim trailing \r for Windows line endings
        const line_end = if (end > start and self.data[end - 1] == '\r') end - 1 else end;
        return self.data[start..line_end];
    }
};

// ── CSS Themes ───────────────────────────────────────────────

const css_dark =
    \\body { background: #1f1f1f; color: rgba(255,255,255,0.9); font-family: -apple-system, system-ui, sans-serif; font-size: 14px; line-height: 1.6; padding: 16px 24px; margin: 0; }
    \\h1 { font-size: 28px; font-weight: bold; margin: 24px 0 16px; padding-bottom: 8px; border-bottom: 1px solid rgba(255,255,255,0.15); }
    \\h2 { font-size: 22px; font-weight: bold; margin: 20px 0 12px; padding-bottom: 6px; border-bottom: 1px solid rgba(255,255,255,0.15); }
    \\h3 { font-size: 18px; font-weight: 600; margin: 16px 0 8px; }
    \\h4 { font-size: 16px; font-weight: 600; margin: 12px 0 6px; }
    \\h5 { font-size: 14px; font-weight: 500; margin: 10px 0 4px; }
    \\h6 { font-size: 13px; font-weight: 500; color: rgba(255,255,255,0.7); margin: 10px 0 4px; }
    \\pre { background: #141414; border-radius: 6px; padding: 12px; overflow-x: auto; }
    \\pre code { font-family: monospace; font-size: 13px; color: rgba(255,255,255,0.9); background: none; padding: 0; }
    \\code { font-family: monospace; font-size: 13px; color: #d999f2; background: #2e2e2e; padding: 2px 5px; border-radius: 3px; }
    \\blockquote { border-left: 3px solid rgba(255,255,255,0.2); padding-left: 12px; color: rgba(255,255,255,0.6); font-style: italic; margin: 12px 0; }
    \\table { border-collapse: collapse; width: 100%; margin: 12px 0; }
    \\td, th { padding: 8px 12px; border: 1px solid rgba(255,255,255,0.15); text-align: left; }
    \\tr:nth-child(odd) { background: #242424; }
    \\tr:nth-child(even) { background: #1a1a1a; }
    \\a { color: #58a6ff; text-decoration: none; }
    \\a:hover { text-decoration: underline; }
    \\hr { border: none; border-top: 1px solid rgba(255,255,255,0.15); margin: 24px 0; }
    \\ul, ol { padding-left: 24px; }
    \\li { margin: 4px 0; }
    \\p { margin: 8px 0; }
;

const css_light =
    \\body { background: #fafafa; color: #1a1a1a; font-family: -apple-system, system-ui, sans-serif; font-size: 14px; line-height: 1.6; padding: 16px 24px; margin: 0; }
    \\h1 { font-size: 28px; font-weight: bold; margin: 24px 0 16px; padding-bottom: 8px; border-bottom: 1px solid rgba(0,0,0,0.1); }
    \\h2 { font-size: 22px; font-weight: bold; margin: 20px 0 12px; padding-bottom: 6px; border-bottom: 1px solid rgba(0,0,0,0.1); }
    \\h3 { font-size: 18px; font-weight: 600; margin: 16px 0 8px; }
    \\h4 { font-size: 16px; font-weight: 600; margin: 12px 0 6px; }
    \\h5 { font-size: 14px; font-weight: 500; margin: 10px 0 4px; }
    \\h6 { font-size: 13px; font-weight: 500; color: rgba(0,0,0,0.5); margin: 10px 0 4px; }
    \\pre { background: #ededed; border-radius: 6px; padding: 12px; overflow-x: auto; }
    \\pre code { font-family: monospace; font-size: 13px; color: #1a1a1a; background: none; padding: 0; }
    \\code { font-family: monospace; font-size: 13px; color: #9933b3; background: #ebebeb; padding: 2px 5px; border-radius: 3px; }
    \\blockquote { border-left: 3px solid rgba(128,128,128,0.4); padding-left: 12px; color: rgba(0,0,0,0.6); font-style: italic; margin: 12px 0; }
    \\table { border-collapse: collapse; width: 100%; margin: 12px 0; }
    \\td, th { padding: 8px 12px; border: 1px solid rgba(0,0,0,0.1); text-align: left; }
    \\tr:nth-child(odd) { background: #f5f5f5; }
    \\tr:nth-child(even) { background: #ffffff; }
    \\a { color: #0969da; text-decoration: none; }
    \\a:hover { text-decoration: underline; }
    \\hr { border: none; border-top: 1px solid rgba(0,0,0,0.1); margin: 24px 0; }
    \\ul, ol { padding-left: 24px; }
    \\li { margin: 4px 0; }
    \\p { margin: 8px 0; }
;
