"""Browser omnibar suggestions, keyboard navigation, and editing UI tests.

Ported from cmuxUITests/BrowserOmnibarSuggestionsUITests.swift (10 tests).
"""

import json
import os
import time
import uuid

from dogtail.predicate import GenericPredicate
from dogtail.rawinput import keyCombo, typeText

from helpers import (
    load_json,
    poll_socket,
    send_v2,
    wait_for_widget,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _poll_until(timeout, predicate, interval=0.15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


def _find_optional(parent, name, role=None):
    pred = GenericPredicate(name=name, roleName=role or "")
    try:
        return parent.findChild(pred, retry=False, requireResult=False)
    except Exception:
        return None


def _contains_example_domain(value):
    v = (value or "").lower()
    return "example.com" in v or "example.org" in v


def _seed_browser_history(socket_path, entries=None):
    """Seed browser history via the V2 socket command so the omnibar
    has deterministic local suggestions."""
    if entries is None:
        entries = [
            {
                "url": "https://example.com/",
                "title": "Example Domain",
                "visitCount": 10,
                "typedCount": 2,
            },
            {
                "url": "https://go.dev/",
                "title": "The Go Programming Language",
                "visitCount": 10,
                "typedCount": 2,
            },
            {
                "url": "https://www.google.com/",
                "title": "Google",
                "visitCount": 10,
                "typedCount": 2,
            },
        ]
    resp = send_v2(
        socket_path,
        "debug.seed_browser_history",
        {"entries": entries},
        timeout=5,
    )
    # If the V2 command is not yet implemented, write the file directly
    if resp is None or resp.get("error"):
        config_dir = os.environ.get(
            "XDG_DATA_HOME", os.path.expanduser("~/.local/share")
        )
        history_dir = os.path.join(config_dir, "cmux")
        os.makedirs(history_dir, exist_ok=True)
        history_path = os.path.join(history_dir, "browser_history.json")
        now = time.time()
        for i, entry in enumerate(entries):
            entry.setdefault("id", uuid.uuid4().hex)
            entry.setdefault("lastVisited", now - i * 120)
        with open(history_path, "w") as f:
            json.dump(entries, f)


def _focus_omnibar(window):
    """Focus the omnibar via Ctrl+L and return the text field widget."""
    keyCombo("<Ctrl>l")
    omnibar = wait_for_widget(
        window, name="BrowserOmnibarTextField", role="text", timeout=6
    )
    return omnibar


def _type_and_wait_for_suggestions(window, omnibar, query, timeout=6):
    """Type *query* into the omnibar and wait for the suggestions popup."""
    suggestions = _find_optional(window, "BrowserOmnibarSuggestions")
    for attempt in range(3):
        keyCombo("<Ctrl>l")
        time.sleep(0.3)
        # Select all and delete to clear
        keyCombo("<Ctrl>a")
        keyCombo("BackSpace")
        typeText(query)

        if _poll_until(
            timeout,
            lambda: _find_optional(window, "BrowserOmnibarSuggestions") is not None,
        ):
            return True
        keyCombo("Escape")
        time.sleep(0.2)
    return _find_optional(window, "BrowserOmnibarSuggestions") is not None


def _is_row_selected(row):
    """Check if a suggestion row reports as selected via its accessible value."""
    if row is None:
        return False
    try:
        desc = row.description or ""
        name = row.name or ""
        return "selected" in desc.lower() or "selected" in name.lower()
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestBrowserOmnibarSuggestions:
    """Tests ported from BrowserOmnibarSuggestionsUITests."""

    def test_omnibar_suggestions_align_to_pill_and_ctrl_n_p(
        self, window, socket_path
    ):
        """Suggestions popup should align with the omnibar pill, and
        Ctrl+N / Ctrl+P should navigate rows. Enter commits."""
        _seed_browser_history(socket_path, entries=[
            {"url": "https://example.com/", "title": "Example Domain",
             "visitCount": 12, "typedCount": 4},
            {"url": "https://example.org/", "title": "Example Organization",
             "visitCount": 9, "typedCount": 3},
            {"url": "https://go.dev/", "title": "The Go Programming Language",
             "visitCount": 6, "typedCount": 1},
        ])

        omnibar = _focus_omnibar(window)

        assert _type_and_wait_for_suggestions(window, omnibar, "exam"), (
            "Expected omnibar suggestions to appear for 'exam'"
        )

        pill = _find_optional(window, "BrowserOmnibarPill")
        suggestions = wait_for_widget(
            window, name="BrowserOmnibarSuggestions", timeout=6
        )
        row0 = wait_for_widget(
            window, name="BrowserOmnibarSuggestions.Row.0", timeout=6
        )

        # Frame alignment checks
        if pill is not None and suggestions is not None:
            pill_pos = pill.position
            pill_size = pill.size
            sug_pos = suggestions.position
            sug_size = suggestions.size

            x_tolerance = 3
            w_tolerance = 3

            assert abs(pill_pos[0] - sug_pos[0]) <= x_tolerance, (
                f"Expected suggestions minX to match omnibar pill minX. "
                f"pill={pill_pos[0]}, sug={sug_pos[0]}"
            )
            assert abs(pill_size[0] - sug_size[0]) <= w_tolerance, (
                f"Expected suggestions width to match omnibar width. "
                f"pill_w={pill_size[0]}, sug_w={sug_size[0]}"
            )
            # Suggestions should be below the pill
            assert sug_pos[1] >= pill_pos[1] + pill_size[1] - 1, (
                "Expected suggestions popup to render below the omnibar"
            )

        # Keyboard navigation
        row1 = _find_optional(window, "BrowserOmnibarSuggestions.Row.1")
        assert row1 is not None, "Expected at least 2 suggestion rows"

        # Ctrl+N moves to row 1
        keyCombo("<Ctrl>n")
        assert _poll_until(3, lambda: _is_row_selected(
            _find_optional(window, "BrowserOmnibarSuggestions.Row.1")
        )), "Expected Ctrl+N to move selection to row 1"

        # Ctrl+P back to row 0
        keyCombo("<Ctrl>p")
        assert _poll_until(3, lambda: _is_row_selected(
            _find_optional(window, "BrowserOmnibarSuggestions.Row.0")
        )), "Expected Ctrl+P to move selection back to row 0"

        # Enter commits the selection
        keyCombo("Return")
        time.sleep(1)

        # Omnibar should now contain the navigated URL
        def _navigated():
            ob = _find_optional(window, "BrowserOmnibarTextField", "text")
            if ob is None:
                return False
            try:
                return _contains_example_domain(ob.text or "")
            except Exception:
                return False

        assert _poll_until(8, _navigated), (
            "Expected omnibar to navigate to example.com after Enter"
        )

    def test_omnibar_escape_and_click_outside(self, window, socket_path):
        """Escape should revert the omnibar to the current URL and close
        suggestions. Second Escape should blur to the web view."""
        _seed_browser_history(socket_path)

        omnibar = _focus_omnibar(window)
        assert _type_and_wait_for_suggestions(window, omnibar, "exam"), (
            "Expected suggestions for 'exam'"
        )

        # Commit to navigate to example.com
        keyCombo("Return")
        assert _poll_until(8, lambda: _contains_example_domain(
            (getattr(_find_optional(window, "BrowserOmnibarTextField", "text"), "text", None) or "")
        )), "Expected committed URL to contain example domain"

        # Type new query, then Escape should revert
        keyCombo("<Ctrl>l")
        typeText("meaning")
        _poll_until(3, lambda: _find_optional(window, "BrowserOmnibarSuggestions") is not None)

        keyCombo("Escape")
        time.sleep(0.3)

        ob = _find_optional(window, "BrowserOmnibarTextField", "text")
        if ob:
            reverted = ob.text or ""
            assert _contains_example_domain(reverted), (
                f"Expected Escape to revert omnibar to current URL. value={reverted}"
            )

        # Suggestions should be closed
        sug_gone = _poll_until(
            1,
            lambda: _find_optional(window, "BrowserOmnibarSuggestions") is None,
        )
        assert sug_gone, "Expected Escape to close suggestions popup"

    def test_omnibar_ctrl_n_p_when_address_bar_focused(
        self, window, socket_path
    ):
        """Ctrl+N/P should navigate suggestion rows when the omnibar
        has focus."""
        _seed_browser_history(socket_path)

        omnibar = _focus_omnibar(window)
        assert _type_and_wait_for_suggestions(window, omnibar, "go"), (
            "Expected suggestions for 'go'"
        )

        row1 = wait_for_widget(
            window, name="BrowserOmnibarSuggestions.Row.1", timeout=6
        )
        row2 = wait_for_widget(
            window, name="BrowserOmnibarSuggestions.Row.2", timeout=6
        )

        keyCombo("<Ctrl>n")
        assert _poll_until(3, lambda: _is_row_selected(
            _find_optional(window, "BrowserOmnibarSuggestions.Row.1")
        )), "Expected Ctrl+N to select row 1"

        keyCombo("<Ctrl>n")
        assert _poll_until(3, lambda: _is_row_selected(
            _find_optional(window, "BrowserOmnibarSuggestions.Row.2")
        )), "Expected repeated Ctrl+N to select row 2"

        keyCombo("<Ctrl>p")
        assert _poll_until(3, lambda: _is_row_selected(
            _find_optional(window, "BrowserOmnibarSuggestions.Row.1")
        )), "Expected Ctrl+P to move back to row 1"

        keyCombo("Escape")

    def test_omnibar_shows_multiple_rows_without_clipping(
        self, window, socket_path
    ):
        """The suggestions popup should show at least 3 rows without
        clipping the third row."""
        _seed_browser_history(socket_path)

        omnibar = _focus_omnibar(window)
        typeText("go")

        suggestions = wait_for_widget(
            window, name="BrowserOmnibarSuggestions", timeout=6
        )
        row2 = wait_for_widget(
            window, name="BrowserOmnibarSuggestions.Row.2", timeout=6
        )

        row2_pos = row2.position
        row2_size = row2.size
        sug_pos = suggestions.position
        sug_size = suggestions.size

        assert row2_size[1] > 1, "Expected third row to have visible height"
        assert row2_pos[1] + row2_size[1] <= sug_pos[1] + sug_size[1] + 1, (
            "Expected third row to stay inside popup bounds"
        )

        keyCombo("Escape")

    def test_ctrl_l_refocus_keeps_omnibar_editable(self, window, socket_path):
        """Pressing Ctrl+L during navigation should keep the omnibar
        editable after the page loads."""
        _seed_browser_history(socket_path)

        omnibar = _focus_omnibar(window)
        typeText("example.com")
        keyCombo("Return")

        # Re-focus immediately
        keyCombo("<Ctrl>l")

        # Wait for navigation to complete
        loaded = _poll_until(8, lambda: _contains_example_domain(
            (getattr(_find_optional(window, "BrowserOmnibarTextField", "text"), "text", None) or "")
        ))
        assert loaded, "Expected omnibar to reflect navigated URL"

        # Type additional characters to verify editability
        typeText("zx")

        def _has_zx():
            ob = _find_optional(window, "BrowserOmnibarTextField", "text")
            if ob is None:
                return False
            val = ob.text or ""
            return "zx" in val

        assert _poll_until(5, _has_zx), (
            "Expected omnibar to keep keyboard focus after Ctrl+L during navigation"
        )

        keyCombo("Escape")

    def test_ctrl_l_immediate_typing_replaces_existing_url(
        self, window, socket_path
    ):
        """Ctrl+L then immediate typing should replace the existing URL
        buffer with the typed prefix."""
        _seed_browser_history(socket_path)

        omnibar = _focus_omnibar(window)
        typeText("example.com")
        keyCombo("Return")

        loaded = _poll_until(8, lambda: _contains_example_domain(
            (getattr(_find_optional(window, "BrowserOmnibarTextField", "text"), "text", None) or "")
        ))
        assert loaded, "Expected baseline navigation to load"

        # Ctrl+L then immediately type
        keyCombo("<Ctrl>l")
        typeText("lo")

        def _starts_with_lo():
            ob = _find_optional(window, "BrowserOmnibarTextField", "text")
            if ob is None:
                return False
            val = (ob.text or "").lower()
            return val.startswith("lo")

        assert _poll_until(7, _starts_with_lo), (
            "Expected immediate typing after Ctrl+L to preserve typed prefix 'lo'"
        )

        keyCombo("Escape")

    def test_omnibar_autocomplete_candidate_committed_on_enter(
        self, window, socket_path
    ):
        """Selecting an autocomplete candidate via Ctrl+N and pressing
        Enter should navigate to that URL."""
        _seed_browser_history(socket_path, entries=[
            {"url": "https://news.ycombinator.com/", "title": "News Y Combinator",
             "visitCount": 12, "typedCount": 1},
            {"url": "https://gmail.com/", "title": "Gmail",
             "visitCount": 10, "typedCount": 2},
        ])

        omnibar = _focus_omnibar(window)
        assert _type_and_wait_for_suggestions(window, omnibar, "gm"), (
            "Expected suggestions for 'gm'"
        )

        # Find the Gmail row and navigate to it
        gmail_row_idx = None
        for i in range(5):
            row = _find_optional(window, f"BrowserOmnibarSuggestions.Row.{i}")
            if row is None:
                break
            try:
                desc = (row.description or row.name or "").lower()
                if "gmail" in desc:
                    gmail_row_idx = i
                    break
            except Exception:
                pass

        if gmail_row_idx is not None and gmail_row_idx > 0:
            for _ in range(gmail_row_idx):
                keyCombo("<Ctrl>n")
            time.sleep(0.3)

        keyCombo("Return")

        committed = _poll_until(8, lambda: "gmail.com" in (
            (getattr(_find_optional(window, "BrowserOmnibarTextField", "text"), "text", None) or "").lower()
        ))
        assert committed, "Expected Enter to commit Gmail autocomplete target"

    def test_omnibar_single_row_popup_minimum_height(self, window, socket_path):
        """A single-row suggestions popup should use the minimum height
        without extra bottom gap."""
        omnibar = _focus_omnibar(window)
        unique_query = f"zzzz-{uuid.uuid4().hex[:8]}"
        typeText(unique_query)

        suggestions = wait_for_widget(
            window, name="BrowserOmnibarSuggestions", timeout=6
        )
        row0 = wait_for_widget(
            window, name="BrowserOmnibarSuggestions.Row.0", timeout=6
        )

        # Verify only one row
        row1 = _find_optional(window, "BrowserOmnibarSuggestions.Row.1")
        assert row1 is None, "Expected one-row popup for a unique query"

        sug_size = suggestions.size
        expected_min_height = 30
        tolerance = 2
        assert abs(sug_size[1] - expected_min_height) <= tolerance, (
            f"Expected one-row popup height ~{expected_min_height}px, "
            f"got {sug_size[1]}"
        )

        # Check balanced insets
        sug_pos = suggestions.position
        row_pos = row0.position
        row_size = row0.size
        top_inset = row_pos[1] - sug_pos[1]
        bottom_inset = (sug_pos[1] + sug_size[1]) - (row_pos[1] + row_size[1])
        assert abs(top_inset - bottom_inset) <= 1.5, (
            f"Expected balanced insets. top={top_inset}, bottom={bottom_inset}"
        )

        keyCombo("Escape")

    def test_inline_autocomplete_backspace_deletes_typed_prefix(
        self, window, socket_path
    ):
        """Pressing Backspace while an inline autocomplete suffix is
        selected should remove one typed prefix character."""
        _seed_browser_history(socket_path)

        omnibar = _focus_omnibar(window)
        typeText("exam")
        time.sleep(0.5)

        # The omnibar should show inline completion (e.g. "example.com")
        ob = _find_optional(window, "BrowserOmnibarTextField", "text")
        if ob:
            val = ob.text or ""
            assert "example.com" in val, (
                f"Expected inline completion for 'exam'. value={val}"
            )

        # Backspace + Escape should leave "exa"
        keyCombo("BackSpace")
        keyCombo("Escape")
        time.sleep(0.3)

        ob = _find_optional(window, "BrowserOmnibarTextField", "text")
        if ob:
            after_val = ob.text or ""
            assert after_val == "exa", (
                f"Expected Backspace to remove one typed prefix char. value={after_val}"
            )

    def test_ctrl_a_select_all_preserves_inline_completion(
        self, window, socket_path
    ):
        """Ctrl+A (Select All) should preserve the inline completion
        display, not collapse to the typed prefix."""
        _seed_browser_history(socket_path)

        omnibar = _focus_omnibar(window)
        typeText("exam")

        # Wait for inline completion
        def _has_inline():
            ob = _find_optional(window, "BrowserOmnibarTextField", "text")
            if ob is None:
                return False
            val = ob.text or ""
            return val.lower().startswith("exam") and len(val) > len("exam")

        assert _poll_until(3, _has_inline), (
            "Expected inline completion to extend typed prefix"
        )

        ob = _find_optional(window, "BrowserOmnibarTextField", "text")
        before_val = ob.text if ob else ""

        keyCombo("<Ctrl>a")
        time.sleep(0.25)

        ob = _find_optional(window, "BrowserOmnibarTextField", "text")
        after_val = ob.text if ob else ""

        assert after_val.lower().startswith("exam") and len(after_val) > len("exam"), (
            f"Expected Ctrl+A to preserve inline completion. "
            f"before={before_val}, after={after_val}"
        )

        keyCombo("Escape")
