//! JavaScript snippets for find-in-page in browser panels.
//!
//! Ports the macOS `BrowserFindJavaScript` enum. Uses TreeWalker to scan
//! text nodes and wraps matches with `<mark>` elements. The current match
//! gets an additional `.current` class and is scrolled into view.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Internal JS fragment: removes existing mark highlights.
// ---------------------------------------------------------------------------

const clear_body =
    \\document.querySelectorAll('mark.__cmux-find').forEach(mark => {
    \\        const parent = mark.parentNode;
    \\        if (!parent) return;
    \\        const text = document.createTextNode(mark.textContent || '');
    \\        parent.replaceChild(text, mark);
    \\        parent.normalize();
    \\      });
;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Returns JS that highlights all occurrences of `query` in the document body.
/// The script evaluates to a JSON string `{"total":N,"current":0}`.
///
/// Caller owns the returned slice and must free it with `allocator.free()`.
pub fn searchScript(allocator: Allocator, query: []const u8) ![]const u8 {
    const escaped = try jsStringEscape(allocator, query);
    defer allocator.free(escaped);

    return std.fmt.allocPrint(allocator,
        \\(() => {{
        \\  const MARK_CLASS = '__cmux-find';
        \\  const CURRENT_CLASS = '__cmux-find-current';
        \\
        \\  {s}
        \\
        \\  const query = "{s}";
        \\  if (!query) return JSON.stringify({{total: 0, current: 0}});
        \\
        \\  const lowerQuery = query.toLowerCase();
        \\  const SKIP_TAGS = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','IFRAME','SVG']);
        \\  const isVisible = (el) => {{
        \\    while (el && el !== document.body) {{
        \\      if (SKIP_TAGS.has(el.tagName)) return false;
        \\      if (el.getAttribute('aria-hidden') === 'true') return false;
        \\      const st = getComputedStyle(el);
        \\      if (st.display === 'none' || st.visibility === 'hidden') return false;
        \\      el = el.parentElement;
        \\    }}
        \\    return true;
        \\  }};
        \\  const walker = document.createTreeWalker(
        \\    document.body,
        \\    NodeFilter.SHOW_TEXT,
        \\    {{ acceptNode(node) {{ return isVisible(node.parentElement) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT; }} }}
        \\  );
        \\  const matches = [];
        \\  const textNodes = [];
        \\  while (walker.nextNode()) textNodes.push(walker.currentNode);
        \\
        \\  for (const node of textNodes) {{
        \\    const text = node.textContent || '';
        \\    const lowerText = text.toLowerCase();
        \\    let startIndex = 0;
        \\    const parts = [];
        \\    let lastEnd = 0;
        \\    while (true) {{
        \\      const idx = lowerText.indexOf(lowerQuery, startIndex);
        \\      if (idx === -1) break;
        \\      parts.push({{ start: idx, end: idx + query.length }});
        \\      startIndex = idx + query.length;
        \\    }}
        \\    if (parts.length === 0) continue;
        \\
        \\    const parent = node.parentNode;
        \\    if (!parent) continue;
        \\    const frag = document.createDocumentFragment();
        \\    let pos = 0;
        \\    for (const part of parts) {{
        \\      if (part.start > pos) {{
        \\        frag.appendChild(document.createTextNode(text.substring(pos, part.start)));
        \\      }}
        \\      const mark = document.createElement('mark');
        \\      mark.className = MARK_CLASS;
        \\      mark.textContent = text.substring(part.start, part.end);
        \\      frag.appendChild(mark);
        \\      matches.push(mark);
        \\      pos = part.end;
        \\    }}
        \\    if (pos < text.length) {{
        \\      frag.appendChild(document.createTextNode(text.substring(pos)));
        \\    }}
        \\    parent.replaceChild(frag, node);
        \\  }}
        \\
        \\  window.__cmuxFindMatches = matches;
        \\  window.__cmuxFindIndex = 0;
        \\
        \\  if (matches.length > 0) {{
        \\    matches[0].classList.add(CURRENT_CLASS);
        \\    matches[0].scrollIntoView({{ block: 'center', behavior: 'smooth' }});
        \\  }}
        \\
        \\  if (!document.getElementById('__cmux-find-style')) {{
        \\    const style = document.createElement('style');
        \\    style.id = '__cmux-find-style';
        \\    style.textContent = `
        \\      mark.__cmux-find {{ background: #facc15; color: #000; border-radius: 2px; }}
        \\      mark.__cmux-find.__cmux-find-current {{ background: #f97316; color: #fff; }}
        \\    `;
        \\    document.head.appendChild(style);
        \\  }}
        \\
        \\  return JSON.stringify({{ total: matches.length, current: 0 }});
        \\}})()
    , .{ clear_body, escaped });
}

/// Returns JS that moves to the next match. Evaluates to `{"total":N,"current":M}`.
pub fn nextScript() []const u8 {
    return
        \\(() => {
        \\  const matches = window.__cmuxFindMatches || [];
        \\  if (matches.length === 0) return JSON.stringify({ total: 0, current: 0 });
        \\  let idx = window.__cmuxFindIndex || 0;
        \\  if (!matches[idx] || !matches[idx].isConnected) {
        \\    window.__cmuxFindMatches = [];
        \\    window.__cmuxFindIndex = 0;
        \\    return JSON.stringify({ total: 0, current: 0 });
        \\  }
        \\  matches[idx].classList.remove('__cmux-find-current');
        \\  idx = (idx + 1) % matches.length;
        \\  if (!matches[idx] || !matches[idx].isConnected) {
        \\    window.__cmuxFindMatches = [];
        \\    window.__cmuxFindIndex = 0;
        \\    return JSON.stringify({ total: 0, current: 0 });
        \\  }
        \\  matches[idx].classList.add('__cmux-find-current');
        \\  matches[idx].scrollIntoView({ block: 'center', behavior: 'smooth' });
        \\  window.__cmuxFindIndex = idx;
        \\  return JSON.stringify({ total: matches.length, current: idx });
        \\})()
    ;
}

/// Returns JS that moves to the previous match. Evaluates to `{"total":N,"current":M}`.
pub fn previousScript() []const u8 {
    return
        \\(() => {
        \\  const matches = window.__cmuxFindMatches || [];
        \\  if (matches.length === 0) return JSON.stringify({ total: 0, current: 0 });
        \\  let idx = window.__cmuxFindIndex || 0;
        \\  if (!matches[idx] || !matches[idx].isConnected) {
        \\    window.__cmuxFindMatches = [];
        \\    window.__cmuxFindIndex = 0;
        \\    return JSON.stringify({ total: 0, current: 0 });
        \\  }
        \\  matches[idx].classList.remove('__cmux-find-current');
        \\  idx = (idx - 1 + matches.length) % matches.length;
        \\  if (!matches[idx] || !matches[idx].isConnected) {
        \\    window.__cmuxFindMatches = [];
        \\    window.__cmuxFindIndex = 0;
        \\    return JSON.stringify({ total: 0, current: 0 });
        \\  }
        \\  matches[idx].classList.add('__cmux-find-current');
        \\  matches[idx].scrollIntoView({ block: 'center', behavior: 'smooth' });
        \\  window.__cmuxFindIndex = idx;
        \\  return JSON.stringify({ total: matches.length, current: idx });
        \\})()
    ;
}

/// Returns JS that removes all find highlights and restores the DOM.
pub fn clearScript() []const u8 {
    return
        \\(() => {
        \\  document.querySelectorAll('mark.__cmux-find').forEach(mark => {
        \\        const parent = mark.parentNode;
        \\        if (!parent) return;
        \\        const text = document.createTextNode(mark.textContent || '');
        \\        parent.replaceChild(text, mark);
        \\        parent.normalize();
        \\      });
        \\  window.__cmuxFindMatches = [];
        \\  window.__cmuxFindIndex = 0;
        \\  const style = document.getElementById('__cmux-find-style');
        \\  if (style) style.remove();
        \\  return 'ok';
        \\})()
    ;
}

/// Escape a string for safe embedding inside a JS double-quoted string literal.
///
/// Mirrors the macOS `BrowserFindJavaScript.jsStringEscape()`.
/// Caller owns the returned slice and must free it with `allocator.free()`.
pub fn jsStringEscape(allocator: Allocator, input: []const u8) ![]const u8 {
    // Count the output length first to do a single allocation.
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        const replacement = escapeCharLen(input, i);
        out_len += replacement.len;
        i += replacement.consumed;
    }

    const buf = try allocator.alloc(u8, out_len);
    errdefer allocator.free(buf);

    var pos: usize = 0;
    i = 0;
    while (i < input.len) {
        const replacement = escapeChar(input, i);
        @memcpy(buf[pos..][0..replacement.bytes.len], replacement.bytes);
        pos += replacement.bytes.len;
        i += replacement.consumed;
    }
    std.debug.assert(pos == out_len);

    return buf;
}

const EscapeResult = struct {
    bytes: []const u8,
    consumed: usize,
};

const EscapeLenResult = struct {
    len: usize,
    consumed: usize,
};

fn escapeCharLen(input: []const u8, i: usize) EscapeLenResult {
    const r = escapeChar(input, i);
    return .{ .len = r.bytes.len, .consumed = r.consumed };
}

fn escapeChar(input: []const u8, i: usize) EscapeResult {
    const b = input[i];
    return switch (b) {
        '\\' => .{ .bytes = "\\\\", .consumed = 1 },
        '"' => .{ .bytes = "\\\"", .consumed = 1 },
        '\n' => .{ .bytes = "\\n", .consumed = 1 },
        '\r' => .{ .bytes = "\\r", .consumed = 1 },
        '\t' => .{ .bytes = "\\t", .consumed = 1 },
        0 => .{ .bytes = "\\0", .consumed = 1 },
        else => blk: {
            // Check for U+2028 LINE SEPARATOR (E2 80 A8) and U+2029 PARAGRAPH SEPARATOR (E2 80 A9).
            if (b == 0xE2 and i + 2 < input.len and input[i + 1] == 0x80) {
                if (input[i + 2] == 0xA8) {
                    break :blk .{ .bytes = "\\u2028", .consumed = 3 };
                }
                if (input[i + 2] == 0xA9) {
                    break :blk .{ .bytes = "\\u2029", .consumed = 3 };
                }
            }
            break :blk .{ .bytes = input[i..][0..1], .consumed = 1 };
        },
    };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

// ---- searchScript tests ----

test "searchScript returns non-empty JS containing the query" {
    const allocator = testing.allocator;
    const js = try searchScript(allocator, "hello");
    defer allocator.free(js);

    try testing.expect(js.len > 0);
    try testing.expect(std.mem.indexOf(u8, js, "hello") != null);
}

test "searchScript empty query returns early return with total: 0" {
    const allocator = testing.allocator;
    const js = try searchScript(allocator, "");
    defer allocator.free(js);

    try testing.expect(std.mem.indexOf(u8, js, "total: 0") != null);
}

// ---- nextScript tests ----

test "nextScript returns valid JS with __cmuxFindMatches" {
    const js = nextScript();
    try testing.expect(js.len > 0);
    try testing.expect(std.mem.indexOf(u8, js, "__cmuxFindMatches") != null);
}

// ---- previousScript tests ----

test "previousScript returns valid JS with __cmuxFindMatches" {
    const js = previousScript();
    try testing.expect(js.len > 0);
    try testing.expect(std.mem.indexOf(u8, js, "__cmuxFindMatches") != null);
}

// ---- clearScript tests ----

test "clearScript returns valid JS with __cmux-find" {
    const js = clearScript();
    try testing.expect(js.len > 0);
    try testing.expect(std.mem.indexOf(u8, js, "__cmux-find") != null);
}

// ---- jsStringEscape tests ----

test "jsStringEscape escapes double quotes" {
    const allocator = testing.allocator;
    const result = try jsStringEscape(allocator, "say \"hello\"");
    defer allocator.free(result);
    try testing.expectEqualStrings("say \\\"hello\\\"", result);
}

test "jsStringEscape escapes backslashes" {
    const allocator = testing.allocator;
    const result = try jsStringEscape(allocator, "path\\to\\file");
    defer allocator.free(result);
    try testing.expectEqualStrings("path\\\\to\\\\file", result);
}

test "jsStringEscape escapes newlines" {
    const allocator = testing.allocator;
    const result = try jsStringEscape(allocator, "line1\nline2");
    defer allocator.free(result);
    try testing.expectEqualStrings("line1\\nline2", result);
}

test "jsStringEscape escapes carriage returns" {
    const allocator = testing.allocator;
    const result = try jsStringEscape(allocator, "line1\rline2");
    defer allocator.free(result);
    try testing.expectEqualStrings("line1\\rline2", result);
}

test "jsStringEscape escapes tabs" {
    const allocator = testing.allocator;
    const result = try jsStringEscape(allocator, "col1\tcol2");
    defer allocator.free(result);
    try testing.expectEqualStrings("col1\\tcol2", result);
}

test "jsStringEscape plain text passes through" {
    const allocator = testing.allocator;
    const result = try jsStringEscape(allocator, "hello world 123");
    defer allocator.free(result);
    try testing.expectEqualStrings("hello world 123", result);
}

test "jsStringEscape Japanese text passes through" {
    const allocator = testing.allocator;
    // U+3053 U+3093 U+306B U+3061 U+306F = "こんにちは" in UTF-8
    const input = "\xe3\x81\x93\xe3\x82\x93\xe3\x81\xab\xe3\x81\xa1\xe3\x81\xaf";
    const result = try jsStringEscape(allocator, input);
    defer allocator.free(result);
    try testing.expectEqualStrings(input, result);
}

test "jsStringEscape mixed special characters" {
    const allocator = testing.allocator;
    // Input: a\"b\nc  (literal backslash, quote, backslash, n, c)
    const result = try jsStringEscape(allocator, "a\\\"b\\nc");
    defer allocator.free(result);
    try testing.expectEqualStrings("a\\\\\\\"b\\\\nc", result);
}

test "jsStringEscape escapes null byte" {
    const allocator = testing.allocator;
    const result = try jsStringEscape(allocator, "a\x00b");
    defer allocator.free(result);
    try testing.expectEqualStrings("a\\0b", result);
}

test "jsStringEscape escapes line separator U+2028" {
    const allocator = testing.allocator;
    // U+2028 = E2 80 A8 in UTF-8
    const result = try jsStringEscape(allocator, "a\xe2\x80\xa8b");
    defer allocator.free(result);
    try testing.expectEqualStrings("a\\u2028b", result);
}

test "jsStringEscape escapes paragraph separator U+2029" {
    const allocator = testing.allocator;
    // U+2029 = E2 80 A9 in UTF-8
    const result = try jsStringEscape(allocator, "a\xe2\x80\xa9b");
    defer allocator.free(result);
    try testing.expectEqualStrings("a\\u2029b", result);
}

// ---- searchScript escaping integration ----

test "searchScript escapes query containing double quotes" {
    const allocator = testing.allocator;
    const js = try searchScript(allocator, "test\"injection");
    defer allocator.free(js);

    // The double quote should be escaped in the output.
    try testing.expect(std.mem.indexOf(u8, js, "test\\\"injection") != null);
    // The raw unescaped form should NOT appear.
    try testing.expect(std.mem.indexOf(u8, js, "test\"injection") == null);
}

test "searchScript handles line separator U+2028" {
    const allocator = testing.allocator;
    const js = try searchScript(allocator, "test\xe2\x80\xa8break");
    defer allocator.free(js);

    try testing.expect(std.mem.indexOf(u8, js, "\\u2028") != null);
}
