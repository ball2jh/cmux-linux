/// CJK IME composition state machine.
///
/// Platform-agnostic state tracking for Input Method Editor (IME)
/// composition used by Korean (한글), Chinese (中文), and Japanese (日本語)
/// input methods.
///
/// Ports the portable portions of the macOS `CJKIMEMarkedTextTests`,
/// `CJKIMEShortcutBypassTests`, and `CJKIMECompositionSequenceTests`.
///
/// This module does NOT port NSTextInputClient, GhosttyNSView,
/// performKeyEquivalent, firstRect, documentVisibleRect, or
/// validAttributesForMarkedText — those are platform-specific.
const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Composition state
// ═══════════════════════════════════════════════════════════════════════

/// IME composition state machine.
///
/// Tracks whether the user is currently composing CJK text (marked text
/// is active), and manages the text accumulator for collecting multiple
/// commits within a single key event.
pub const CompositionState = struct {
    /// The current marked (preedit) text, or null if no composition is active.
    marked_text: ?[]const u8 = null,
    marked_text_len: usize = 0,

    /// Text accumulator: collects committed text segments during a single
    /// keyDown event. When null, text should be sent directly to the terminal.
    /// When non-null (even if empty), text is accumulated for batch sending.
    accumulator: ?std.ArrayList([]const u8) = null,

    // Storage for marked text (we copy it since the caller owns the original).
    marked_buf: [256]u8 = undefined,

    /// Returns true if there is active marked (preedit) text.
    pub fn hasMarkedText(self: *const CompositionState) bool {
        return self.marked_text != null and self.marked_text_len > 0;
    }

    /// Returns the length of the current marked text, or 0 if none.
    pub fn markedTextLength(self: *const CompositionState) usize {
        return if (self.marked_text != null) self.marked_text_len else 0;
    }

    /// Set marked text (preedit string from the IME).
    /// An empty string clears the composition state.
    pub fn setMarkedText(self: *CompositionState, text: []const u8) void {
        if (text.len == 0) {
            self.marked_text = null;
            self.marked_text_len = 0;
            return;
        }
        const copy_len = @min(text.len, self.marked_buf.len);
        @memcpy(self.marked_buf[0..copy_len], text[0..copy_len]);
        self.marked_text = self.marked_buf[0..copy_len];
        self.marked_text_len = copy_len;
    }

    /// Clear marked text (commit or cancel composition).
    /// This is called when the IME commits the composed text or the user
    /// cancels composition (e.g., via Escape).
    pub fn unmarkText(self: *CompositionState) void {
        self.marked_text = null;
        self.marked_text_len = 0;
    }

    /// Begin text accumulation for a keyDown event.
    pub fn beginAccumulation(self: *CompositionState, alloc: std.mem.Allocator) void {
        if (self.accumulator == null) {
            self.accumulator = std.ArrayList([]const u8).init(alloc);
        }
    }

    /// Add text to the accumulator.
    pub fn accumulateText(self: *CompositionState, text: []const u8) !void {
        if (self.accumulator) |*acc| {
            try acc.append(text);
        }
    }

    /// End text accumulation and return the collected segments.
    pub fn endAccumulation(self: *CompositionState) ?[]const []const u8 {
        if (self.accumulator) |acc| {
            const items = acc.items;
            self.accumulator = null;
            return items;
        }
        return null;
    }

    /// Reset the accumulator without returning its contents.
    pub fn resetAccumulator(self: *CompositionState) void {
        if (self.accumulator) |*acc| {
            acc.deinit();
            self.accumulator = null;
        }
    }

    /// Whether shortcut processing should be bypassed.
    /// During active IME composition, keyboard shortcuts must not fire
    /// because the key events need to flow through to the input method.
    pub fn shouldBypassShortcuts(self: *const CompositionState) bool {
        return self.hasMarkedText();
    }
};

/// Determine whether a Shift+Space key event should be suppressed.
/// When there is no marked text, Shift+Space is a shortcut (e.g., toggle IME).
/// During composition, it should flow through normally.
pub fn shouldSuppressShiftSpace(has_marked_text: bool) bool {
    return !has_marked_text;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

const testing = std.testing;

// ── Korean (한글) jamo combining ────────────────────────────────────

test "korean jamo combining set marked text creates marked state" {
    var state = CompositionState{};

    try testing.expect(!state.hasMarkedText());

    // First jamo: ㅎ (hieut)
    state.setMarkedText("\xe3\x85\x8e"); // ㅎ
    try testing.expect(state.hasMarkedText());
    try testing.expectEqual(@as(usize, 3), state.markedTextLength());

    // Combined syllable: 하 (ha)
    state.setMarkedText("\xed\x95\x98"); // 하
    try testing.expect(state.hasMarkedText());
    try testing.expectEqual(@as(usize, 3), state.markedTextLength());

    // Further combined: 한 (han)
    state.setMarkedText("\xed\x95\x9c"); // 한
    try testing.expect(state.hasMarkedText());
}

test "korean insert text commits and clears marked text" {
    var state = CompositionState{};

    // Simulate composition in progress.
    state.setMarkedText("\xed\x95\x9c"); // 한
    try testing.expect(state.hasMarkedText());

    // unmarkText clears marked text (as insertText does).
    state.unmarkText();
    try testing.expect(!state.hasMarkedText());
    try testing.expectEqual(@as(usize, 0), state.markedTextLength());
}

// ── Chinese (中文) pinyin candidate selection ───────────────────────

test "chinese pinyin marked text during typing" {
    var state = CompositionState{};

    state.setMarkedText("n");
    try testing.expect(state.hasMarkedText());
    try testing.expectEqual(@as(usize, 1), state.markedTextLength());

    state.setMarkedText("ni");
    try testing.expect(state.hasMarkedText());
    try testing.expectEqual(@as(usize, 2), state.markedTextLength());

    state.setMarkedText("nih");
    try testing.expect(state.hasMarkedText());

    state.setMarkedText("niha");
    try testing.expect(state.hasMarkedText());

    state.setMarkedText("nihao");
    try testing.expect(state.hasMarkedText());
}

test "chinese pinyin candidate selection clears marked text" {
    var state = CompositionState{};

    state.setMarkedText("nihao");
    try testing.expect(state.hasMarkedText());

    state.unmarkText();
    try testing.expect(!state.hasMarkedText());
}

// ── Japanese (日本語) hiragana-to-kanji conversion ──────────────────

test "japanese hiragana composition" {
    var state = CompositionState{};

    state.setMarkedText("\xe3\x81\xab"); // に
    try testing.expect(state.hasMarkedText());

    state.setMarkedText("\xe3\x81\xab\xe3\x81\xbb"); // にほ
    try testing.expect(state.hasMarkedText());
    try testing.expectEqual(@as(usize, 6), state.markedTextLength());

    state.setMarkedText("\xe3\x81\xab\xe3\x81\xbb\xe3\x82\x93"); // にほん
    try testing.expect(state.hasMarkedText());

    state.setMarkedText("\xe3\x81\xab\xe3\x81\xbb\xe3\x82\x93\xe3\x81\x94"); // にほんご
    try testing.expect(state.hasMarkedText());
}

test "japanese kanji conversion keeps marked text until commit" {
    var state = CompositionState{};

    state.setMarkedText("\xe3\x81\xab\xe3\x81\xbb\xe3\x82\x93\xe3\x81\x94"); // にほんご
    try testing.expect(state.hasMarkedText());

    // Space triggers conversion — kanji candidate still marked.
    state.setMarkedText("\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e"); // 日本語
    try testing.expect(state.hasMarkedText());

    state.unmarkText();
    try testing.expect(!state.hasMarkedText());
}

// ── unmarkText clears composition state ─────────────────────────────

test "unmark text clears composition state" {
    var state = CompositionState{};

    state.setMarkedText("\xe3\x85\x8e"); // ㅎ
    try testing.expect(state.hasMarkedText());

    state.unmarkText();
    try testing.expect(!state.hasMarkedText());
    try testing.expectEqual(@as(usize, 0), state.markedTextLength());
}

test "unmark text is idempotent" {
    var state = CompositionState{};

    // Call unmarkText when there's no marked text — should be a no-op.
    state.unmarkText();
    try testing.expect(!state.hasMarkedText());

    // Call again — still no-op.
    state.unmarkText();
    try testing.expect(!state.hasMarkedText());
}

// ── Shortcut bypass ─────────────────────────────────────────────────

test "has marked text tracks CJK composition lifecycle" {
    var state = CompositionState{};

    // No marked text — shortcuts should be eligible to fire.
    try testing.expect(!state.hasMarkedText());
    try testing.expect(!state.shouldBypassShortcuts());

    // Active Korean composition — shortcuts must be bypassed.
    state.setMarkedText("\xed\x95\x9c"); // 한
    try testing.expect(state.hasMarkedText());
    try testing.expect(state.shouldBypassShortcuts());

    // After unmarkText — shortcuts should be eligible again.
    state.unmarkText();
    try testing.expect(!state.hasMarkedText());
    try testing.expect(!state.shouldBypassShortcuts());
}

test "has marked text transitions through chinese composition" {
    var state = CompositionState{};

    try testing.expect(!state.hasMarkedText());

    state.setMarkedText("zhong");
    try testing.expect(state.hasMarkedText());

    state.unmarkText();
    try testing.expect(!state.hasMarkedText());
}

test "has marked text transitions through japanese composition" {
    var state = CompositionState{};

    try testing.expect(!state.hasMarkedText());

    // Hiragana composition.
    state.setMarkedText("\xe3\x81\xa8\xe3\x81\x86\xe3\x81\x8d\xe3\x82\x87\xe3\x81\x86"); // とうきょう
    try testing.expect(state.hasMarkedText());

    // Kanji conversion (still marked).
    state.setMarkedText("\xe6\x9d\xb1\xe4\xba\xac"); // 東京
    try testing.expect(state.hasMarkedText());

    // Confirm.
    state.unmarkText();
    try testing.expect(!state.hasMarkedText());
}

// ── Multi-syllable Korean sequence ──────────────────────────────────

test "korean multi-syllable sequence" {
    var state = CompositionState{};

    // First syllable: 안 (an)
    state.setMarkedText("\xe3\x85\x87"); // ㅇ
    try testing.expect(state.hasMarkedText());
    state.setMarkedText("\xec\x95\x84"); // 아
    try testing.expect(state.hasMarkedText());
    state.setMarkedText("\xec\x95\x88"); // 안
    try testing.expect(state.hasMarkedText());

    // Commit first syllable.
    state.unmarkText();
    try testing.expect(!state.hasMarkedText());

    // Second syllable: 녕 (nyeong)
    state.setMarkedText("\xe3\x84\xb4"); // ㄴ
    try testing.expect(state.hasMarkedText());
    state.setMarkedText("\xeb\x85\x80"); // 녀
    try testing.expect(state.hasMarkedText());
    state.setMarkedText("\xeb\x85\x95"); // 녕
    try testing.expect(state.hasMarkedText());

    state.unmarkText();
    try testing.expect(!state.hasMarkedText());
}

// ── Japanese romaji to kanji full sequence ──────────────────────────

test "japanese romaji to kanji full sequence" {
    var state = CompositionState{};

    // Romaji "t"
    state.setMarkedText("t");
    try testing.expect(state.hasMarkedText());

    // Hiragana と
    state.setMarkedText("\xe3\x81\xa8");
    try testing.expect(state.hasMarkedText());

    // Continue to とk
    state.setMarkedText("\xe3\x81\xa8k");
    try testing.expect(state.hasMarkedText());

    // ときょ
    state.setMarkedText("\xe3\x81\xa8\xe3\x81\x8d\xe3\x82\x87");
    try testing.expect(state.hasMarkedText());

    // とうきょう
    state.setMarkedText("\xe3\x81\xa8\xe3\x81\x86\xe3\x81\x8d\xe3\x82\x87\xe3\x81\x86");
    try testing.expect(state.hasMarkedText());

    // Kanji conversion: 東京
    state.setMarkedText("\xe6\x9d\xb1\xe4\xba\xac");
    try testing.expect(state.hasMarkedText());

    // Confirm
    state.unmarkText();
    try testing.expect(!state.hasMarkedText());
}

// ── Chinese pinyin with correction ──────────────────────────────────

test "chinese pinyin with correction" {
    var state = CompositionState{};

    state.setMarkedText("z");
    state.setMarkedText("zh");
    state.setMarkedText("zho");
    try testing.expect(state.hasMarkedText());

    // Backspace corrects to "zh"
    state.setMarkedText("zh");
    try testing.expect(state.hasMarkedText());
    try testing.expectEqual(@as(usize, 2), state.markedTextLength());

    // Re-type "zhong"
    state.setMarkedText("zhong");
    try testing.expect(state.hasMarkedText());

    // Commit
    state.unmarkText();
    try testing.expect(!state.hasMarkedText());
}

// ── Cancel composition clears marked text ───────────────────────────

test "cancel composition clears marked text" {
    var state = CompositionState{};

    state.setMarkedText("\xe3\x85\x8e"); // ㅎ
    try testing.expect(state.hasMarkedText());

    state.unmarkText();
    try testing.expect(!state.hasMarkedText());
    try testing.expectEqual(@as(usize, 0), state.markedTextLength());
}

test "cancel composition via empty set marked text" {
    var state = CompositionState{};

    state.setMarkedText("\xe3\x81\xab\xe3\x81\xbb\xe3\x82\x93"); // にほん
    try testing.expect(state.hasMarkedText());

    // Cancel by setting empty marked text.
    state.setMarkedText("");
    try testing.expect(!state.hasMarkedText());
}

// ── Rapid composition transitions ───────────────────────────────────

test "rapid composition transitions" {
    var state = CompositionState{};

    // Rapidly cycle: compose -> commit -> compose -> commit
    for ([_][]const u8{ "\xe3\x85\x8e", "\xed\x95\x98", "\xed\x95\x9c" }) |char| {
        state.setMarkedText(char);
        try testing.expect(state.hasMarkedText());
    }

    state.unmarkText();
    try testing.expect(!state.hasMarkedText());

    for ([_][]const u8{ "\xe3\x84\xb1", "\xea\xb5\xac", "\xea\xb8\x80" }) |char| {
        state.setMarkedText(char);
        try testing.expect(state.hasMarkedText());
    }

    state.unmarkText();
    try testing.expect(!state.hasMarkedText());
}

// ── Shift+Space suppression ─────────────────────────────────────────

test "shift+space suppressed when no marked text" {
    try testing.expect(shouldSuppressShiftSpace(false));
}

test "shift+space not suppressed during composition" {
    try testing.expect(!shouldSuppressShiftSpace(true));
}

// ── Additional CJK IME edge cases ───────────────────────────────────

test "endAccumulation without begin returns null" {
    var state = CompositionState{};
    try testing.expect(state.endAccumulation() == null);
}

test "setMarkedText with empty string clears state" {
    var state = CompositionState{};
    state.setMarkedText("something");
    try testing.expect(state.hasMarkedText());

    state.setMarkedText("");
    try testing.expect(!state.hasMarkedText());
    try testing.expectEqual(@as(usize, 0), state.markedTextLength());
}

test "shouldBypassShortcuts returns false after unmark" {
    var state = CompositionState{};
    state.setMarkedText("test");
    try testing.expect(state.shouldBypassShortcuts());

    state.unmarkText();
    try testing.expect(!state.shouldBypassShortcuts());
}

test "composition state is independent between instances" {
    var state1 = CompositionState{};
    var state2 = CompositionState{};

    state1.setMarkedText("hello");
    try testing.expect(state1.hasMarkedText());
    try testing.expect(!state2.hasMarkedText());
}

test "marked text length matches utf8 byte count" {
    var state = CompositionState{};
    // Korean 한 = 3 bytes in UTF-8
    state.setMarkedText("\xed\x95\x9c");
    try testing.expectEqual(@as(usize, 3), state.markedTextLength());

    // Two Korean characters = 6 bytes
    state.setMarkedText("\xed\x95\x9c\xea\xb5\xad");
    try testing.expectEqual(@as(usize, 6), state.markedTextLength());
}

test "multiple unmark calls are safe" {
    var state = CompositionState{};
    state.setMarkedText("test");
    state.unmarkText();
    state.unmarkText();
    state.unmarkText();
    try testing.expect(!state.hasMarkedText());
}
