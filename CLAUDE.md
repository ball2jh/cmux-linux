# cmux-linux agent notes

## Reference implementation

The **macOS version** lives at `~/Projects/cmux-macos` (Swift/Xcode). It is the canonical reference — **our goal is feature parity**. Every feature, command, and behavior in the Mac version should be replicated on Linux in Zig, unless it is platform-impossible (e.g. Sparkle, WKWebView CDP, macOS Services).

When implementing a feature, **always read the Mac implementation first** and port the logic faithfully. The expectation is to copy the macOS structure exactly — same file organization, same module boundaries, same data flow — except written in Zig for GTK/Linux. Only deviate where:
- The platform requires it (e.g. GTK vs AppKit, WebKitGTK vs WKWebView, GLib vs GCD)
- Zig offers a genuinely better approach than Swift for the same problem (e.g. comptime, tagged unions, explicit allocators)

Match the same socket command names, response shapes, CLI arguments, error codes, and data model fields.

**Appearance must be nearly identical to the Mac version.** Same sidebar layout, same workspace rows, same notification UI, same command palette look. Use GTK/Adwaita to get as close as possible — only accept visual differences when GTK literally cannot reproduce the Mac behavior.

## Build

```bash
sudo pacman -S zig gtk4 libadwaita gtk4-layer-shell webkitgtk-6.0 blueprint-compiler pkgconf
zig build -Dcmux=true -Dversion-string="0.1.0-dev"
./zig-out/bin/cmux
```

`-Dcmux=true` is required — without it, a standard Ghostty binary is produced.

## Run

```bash
./zig-out/bin/cmux
```

This is a GTK single-instance app. If an instance is already running, the new process activates the existing one and exits. To force a fresh instance, kill existing ones first: `pkill -f cmux`.

## Pitfalls

- **All cmux code in `src/cmux/`** — do not scatter cmux logic into Ghostty core files.
- **Socket command names use underscores** (not hyphens) — matches Mac protocol.
- **WebKitGTK != WKWebView** — browser automation commands that rely on WKWebView internals need WebKitGTK equivalents or stubs.
