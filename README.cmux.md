# cmux for Linux

A GPU-accelerated terminal for AI coding agents, built on [Ghostty](https://ghostty.org). Linux port of [cmux](https://github.com/manaflow-ai/cmux).

## Features

- **Socket control API** -- AI agents connect via Unix socket to control the terminal
- **Dual protocol** -- V1 text commands + V2 JSON-RPC on the same socket
- **Send/read terminal** -- Inject text and read screen content programmatically
- **Notifications** -- OSC 777 interception, in-memory store, desktop notifications
- **Workspaces** -- Named groups of tabs, sidebar, session persistence
- **Browser panel API** -- Open/navigate/query browser panels (WebKitGTK rendering in progress)
- **Session persistence** -- Autosaves every 8s, restores workspaces on restart
- **Authentication** -- SO_PEERCRED-based auth (same-user or process ancestry check)

## Install

### AUR (Arch Linux)

```bash
# Using an AUR helper (e.g., yay, paru)
yay -S cmux-git

# Or manually
git clone https://github.com/ball2jh/cmux-linux.git /tmp/cmux-build
cd /tmp/cmux-build/aur
makepkg -si
```

### Build from source

```bash
# Dependencies (Arch)
sudo pacman -S zig gtk4 libadwaita gtk4-layer-shell webkitgtk-6.0 blueprint-compiler pkgconf

# Build
git clone https://github.com/ball2jh/cmux-linux.git
cd cmux-linux
zig build -Dcmux=true -Dversion-string="0.1.0-dev" -Doptimize=ReleaseFast

# Run
./zig-out/bin/cmux
```

## Usage

### CLI

```bash
cmux +ctl ping              # Check if cmux is running
cmux +ctl version            # Get version
cmux +ctl send "echo hello"  # Type into active terminal
cmux +ctl read-screen        # Read terminal viewport
cmux +ctl list-windows       # List open windows
cmux +ctl new-window         # Open a new window
cmux +ctl list-workspaces    # List workspaces
cmux +ctl new-workspace dev  # Create workspace "dev"
cmux +ctl notify "Build done"  # Create notification
cmux +ctl open-browser "http://localhost:3000"  # Open browser panel
```

### Socket API (V1)

Connect to `/tmp/cmux-{uid}.sock` and send newline-delimited commands:

```
ping
version
send echo hello
read-screen
new-window
list-windows
close-window
list-workspaces
new-workspace <name>
select-workspace <id>
close-workspace <id>
rename-workspace <id> <name>
current-workspace
notify <title> [body]
list-notifications
clear-notifications
open-browser <url>
navigate <id> <url>
get-url <id>
quit
```

### Socket API (V2 JSON-RPC)

Send JSON on the same socket (auto-detected by `{` prefix):

```json
{"id":"1","method":"system.ping","params":{}}
{"id":"2","method":"surface.read_text","params":{}}
{"id":"3","method":"workspace.create","params":{"name":"dev"}}
{"id":"4","method":"browser.open","params":{"url":"http://localhost:3000"}}
```

Response format:
```json
{"id":"1","ok":true,"result":"pong"}
{"id":"1","ok":false,"error":{"code":"not_found","message":"..."}}
```

**Available V2 methods:** `system.ping`, `system.version`, `system.capabilities`, `window.list`, `window.create`, `surface.read_text`, `workspace.list`, `workspace.current`, `workspace.create`, `workspace.select`, `workspace.close`, `workspace.rename`, `notification.list`, `notification.clear`, `browser.open`, `browser.navigate`, `browser.url.get`, `browser.list`

## Architecture

cmux-linux is a fork of [manaflow-ai/ghostty](https://github.com/manaflow-ai/ghostty) (which itself forks [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty)). All cmux-specific code lives under `src/cmux/` to minimize merge conflicts with upstream.

Build with `-Dcmux=true` to produce the cmux binary. Without it, a standard Ghostty binary is produced.

## License

- Ghostty base: MIT (Mitchell Hashimoto, Ghostty contributors)
- cmux additions (`src/cmux/`): AGPL-3.0-or-later
