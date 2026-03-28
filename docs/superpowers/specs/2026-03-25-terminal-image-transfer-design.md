# Terminal Image Transfer — Design Spec

## Overview

Port the macOS `TerminalImageTransfer.swift` feature to Linux/GTK in Zig. When a user pastes or drops files/images onto a terminal surface, the system detects the content type and target (local vs remote SSH), then either inserts shell-escaped paths or uploads files via SCP and inserts the remote paths.

## Reference

- **macOS source**: `~/Projects/cmux-macos/Sources/TerminalImageTransfer.swift`
- **macOS pasteboard helper**: `GhosttyPasteboardHelper` in `GhosttyTerminalView.swift`
- **macOS SSH detection**: `TerminalSSHSessionDetector.swift`
- **macOS workspace upload**: `Workspace.swift` (`uploadDroppedFilesLocked`, `scpExec`)

## Scope

### In Scope

- Paste interception: detect file URIs, raw image data, or text in clipboard
- Drop interception: route dropped files through the planner
- Local target: insert shell-escaped file paths into terminal
- Remote target (workspace-remote): SCP upload via `SessionController`
- Remote target (detected SSH): SCP upload via `SshSessionDetector.buildScpArgs`
- Raw image data: save clipboard image to temp PNG before processing
- Cancellable upload operations with cleanup
- Upload progress overlay (spinner + cancel button, 150ms delay)
- Target resolution: local vs workspace-remote vs detected-SSH

### Out of Scope

- Terminal image protocols (sixel, kitty graphics, iTerm2 inline images)
- Browser image copy (`BrowserImageCopyPasteboardPayload`) — separate feature
- RTFD / attributed string clipboard parsing — not applicable on Linux

## Architecture

### New Files

| File | Purpose |
|------|---------|
| `src/cmux/image_transfer.zig` | Core planner, operation, and plan types |

### Modified Files

| File | Change |
|------|--------|
| `src/apprt/gtk/class/surface.zig` | Hook `Clipboard.request()` and `dtDrop()` to route through planner |
| `src/cmux/remote/SessionController.zig` | Add `uploadDroppedFiles()` for workspace-remote SCP |
| `src/cmux/workspace/Workspace.zig` | Add `uploadDroppedFilesForRemoteTerminal()` delegation wrapper |

## Data Model

Matches macOS enum names and cases exactly:

```
Mode = .paste | .drop

RemoteUploadTarget = .workspace_remote | .detected_ssh(DetectedSession)

Target = .local | .remote(RemoteUploadTarget)

PreparedContent = .insert_text([]const u8) | .file_paths([][]const u8) | .reject

Plan = .insert_text([]const u8) | .upload_files([][]const u8, RemoteUploadTarget) | .reject
```

### Operation

Thread-safe state machine matching macOS `TerminalImageTransferOperation`:

```
State = .running | .cancelled | .finished

Fields:
  mutex: std.Thread.Mutex
  state: State
  cancellation_fn: ?*const fn () void
```

Methods: `cancel() bool`, `finish() bool`, `isCancelled() bool`, `installCancellationHandler()`, `clearCancellationHandler()`, `throwIfCancelled() !void`.

## Core Logic — `image_transfer.zig`

### Planner

All functions are stateless (namespace, not struct), matching macOS `TerminalImageTransferPlanner`.

#### `preparePaste(clipboard: *gdk.Clipboard, callback: ...) void`

Async. Reads clipboard in priority order:

1. **File URIs** (`text/uri-list`): Parse URI list, filter to `file://` URIs, convert to local paths → `.file_paths`
2. **Plain text** (`text/plain;charset=utf-8`, `UTF8_STRING`): If non-empty → `.insert_text`
3. **Image data** (`image/png`, `image/jpeg`, `image/tiff`, `image/gif`): Save to temp file via `saveClipboardImage()` → `.file_paths` with single temp path
4. **URL** (`text/x-moz-url`): Shell-escape → `.insert_text`
5. Otherwise → `.reject`

#### `prepareDrop(file_paths: [][]const u8) PreparedContent`

Synchronous. The GTK drop target already provides file paths:

1. If `file_paths` is non-empty → `.file_paths`
2. Otherwise → `.reject`

(Text drops are handled by the existing `dtDrop` string path, unchanged.)

#### `plan(content: PreparedContent, target: Target) Plan`

Synchronous, pure:

- `.insert_text(text)` → `.insert_text(text)`
- `.file_paths(paths)` + `.local` → `.insert_text(escaped paths joined by space)`
- `.file_paths(paths)` + `.remote(target)` → if all paths are regular files: `.upload_files(paths, target)`, else: `.insert_text(escaped paths)`
- `.reject` → `.reject`

#### `execute(...)`

Dispatches based on plan:

- `.insert_text` → call `insertText` callback directly
- `.upload_files(.workspace_remote)` → call workspace upload callback
- `.upload_files(.detected_ssh(session))` → call detected-SSH upload callback
- `.reject` → no-op

Returns an `Operation` handle for upload plans (caller uses it for indicator + cancellation).

#### `remoteDropPath(extension: []const u8) []const u8`

Returns `/tmp/cmux-drop-{uuid}.{ext}` (lowercase UUID, lowercase extension). Matches macOS `WorkspaceRemoteSessionController.remoteDropPath`.

#### `saveClipboardImage(texture: *gdk.Texture) ?[]const u8`

Saves GDK texture to a temp PNG file:

- Filename: `cmux-paste-{YYYY-MM-DD-HHmmss}-{8-char-uuid}.png`
- Location: `/tmp/`
- Max size: 10 MB (reject if larger)
- Uses `gdk.Texture.saveToPng()` or `gdk.Texture.saveToTiffFilename()` as appropriate
- Registers file for cleanup on process exit

### Target Resolution

`resolveTarget(surface: *Surface) Target`:

1. Get owning workspace
2. If workspace has a remote session for this surface → `.remote(.workspace_remote)`
3. Get surface TTY name; if `SshSessionDetector.detect()` finds an SSH session → `.remote(.detected_ssh(session))`
4. Otherwise → `.local`

## GTK Integration

### Clipboard Paste Interception

**In `Clipboard.request()`** (surface.zig):

Current flow: `readTextAsync` → `clipboardReadText` callback → `completeClipboardRequest`.

New flow:
1. Check clipboard formats synchronously via `getFormats()`
2. If formats contain `text/uri-list` or image MIME types:
   - Read the appropriate format async (`readValueAsync` for textures, `readTextAsync` for URI lists)
   - In the callback, call `image_transfer.preparePaste...` then `plan()` then `execute()`
   - For upload plans: show indicator overlay, spawn upload thread, on completion insert text + hide indicator
3. If clipboard contains only text: fall through to existing `readTextAsync` path (no change)

### Drop Interception

**In `dtDrop()`** (surface.zig):

Current flow: Extract file paths → shell-escape → `Clipboard.paste()`.

New flow for `FileList` and `File` value types:
1. Collect file paths as before
2. Call `image_transfer.prepareDrop(paths)`
3. Resolve target via `resolveTarget()`
4. Call `image_transfer.plan()` then `execute()`
5. For upload plans: show indicator, spawn upload, etc.

The existing `string` drop path is unchanged.

### Upload Progress Overlay

A small widget overlaid on `terminal_page` (the `gtk.Overlay`):

- **Components**: `gtk.Spinner` (24×24) + `gtk.Label` ("Uploading...") + `gtk.Button` (cancel icon)
- **Container**: Horizontal `gtk.Box` with `gtk.Frame` styling, centered in the overlay
- **Show delay**: 150ms via `g_timeout_add` (avoids flash for fast transfers)
- **Hide**: Immediate on `Operation.finish()` or `Operation.cancel()`
- **Cancel action**: Calls `Operation.cancel()`, which triggers the cancellation handler to kill the SCP child process

Implementation: Add the overlay widget in the surface template (`.blp` file) or create it programmatically. Hidden by default. Managed by `beginImageTransferIndicator()` / `endImageTransferIndicator()` methods on the surface.

## SCP Upload

### Workspace-Remote Upload

**`SessionController.uploadDroppedFiles()`**:

- Takes `file_paths: [][]const u8`, `operation: *Operation`, `callback: fn(Result) void`
- Spawns work on a thread (via `std.Thread.spawn`)
- For each file:
  - Check `operation.throwIfCancelled()`
  - Generate remote path via `remoteDropPath()`
  - Build SCP args via `ssh_args.buildScpArgs(config, local_path, "dest:remote_path")`
  - Spawn `scp` child process via `std.process.Child`
  - Wait with 45-second timeout
  - On non-zero exit: extract stderr, call `cleanupUploadedRemotePaths()`, return error
- On success: callback with list of remote paths
- On cancellation/error: cleanup all uploaded paths via SSH `rm -f`

### Detected-SSH Upload

Same logic but uses `SshSessionDetector.buildScpArgs()` instead of `ssh_args.buildScpArgs()`.

### Cleanup

`cleanupUploadedRemotePaths(remote_paths, ssh_args)`:

- Constructs `rm -f -- '/tmp/cmux-drop-xxx' '/tmp/cmux-drop-yyy'`
- Wraps in `sh -c '...'`
- Executes via SSH with 8-second timeout
- Fire-and-forget (errors ignored)

## Error Handling

| Error | Behavior |
|-------|----------|
| Clipboard has no usable content | `.reject` — paste falls through to default Ghostty handling |
| Image too large (>10 MB) | `.reject` — log warning, no paste |
| Temp file write failure | `.reject` — log error |
| SCP exit non-zero | Hide indicator, log error with stderr detail, cleanup uploaded files |
| SCP timeout (45s) | Kill process, treat as error, cleanup |
| Upload cancelled | Kill SCP process, cleanup already-uploaded files |
| Invalid file URL (not regular file) | Fall back to `.insert_text` with escaped paths |

## Testing Strategy

### Unit Tests (in `image_transfer.zig`)

- `plan()` with all combinations of `PreparedContent` × `Target`
- `remoteDropPath()` format validation
- `Operation` state machine transitions (cancel, finish, double-cancel, etc.)
- `escapeForShell()` edge cases (already tested in `url_resolve.zig`)

### Integration Tests (in `tests/`)

- Mock SCP binary that records arguments and exits 0 → verify upload flow
- Mock SCP binary that exits non-zero → verify cleanup
- Cancellation mid-upload → verify cleanup of partial uploads

## File Size Limits

- Clipboard image save: 10 MB max (matching macOS `maxClipboardImageSize`)
- SCP upload timeout: 45 seconds per file
- SCP cleanup timeout: 8 seconds
- No limit on file drops from file manager (user's intent is explicit)
