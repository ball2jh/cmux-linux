//! Remote shell bootstrap scripts for session isolation.
//!
//! Generates shell init files (Zsh/Bash) that:
//!   1. Set an isolated ZDOTDIR (Zsh) to avoid clobbering user config
//!   2. Source the user's real dotfiles
//!   3. Export CMUX_SOCKET_PATH for relay communication
//!   4. Optionally run a startup command
//!
//! Matches macOS RemoteRelayZshBootstrap (RemoteRelayZshBootstrap.swift).

const std = @import("std");

/// Generate the Zsh .zshenv content for an isolated session.
/// The isolated directory is `shell_state_dir` (e.g., ~/.cmux/relay/<port>.shell).
pub fn zshEnv(buf: []u8, shell_state_dir: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    try w.print(
        \\# cmux remote session bootstrap — .zshenv
        \\# Preserve the real ZDOTDIR so we can source user's dotfiles.
        \\if [ -z "$CMUX_REAL_ZDOTDIR" ]; then
        \\  export CMUX_REAL_ZDOTDIR="${{ZDOTDIR:-$HOME}}"
        \\fi
        \\
        \\# Source user's .zshenv if it exists (may change ZDOTDIR).
        \\[ -f "$CMUX_REAL_ZDOTDIR/.zshenv" ] && source "$CMUX_REAL_ZDOTDIR/.zshenv"
        \\
        \\# Re-capture any ZDOTDIR changes from user's .zshenv.
        \\CMUX_REAL_ZDOTDIR="${{ZDOTDIR:-$CMUX_REAL_ZDOTDIR}}"
        \\
        \\# Re-set ZDOTDIR to isolated shell state dir.
        \\export ZDOTDIR="{s}"
        \\
    , .{shell_state_dir});

    return fbs.getWritten();
}

/// Generate the Zsh .zshrc content.
pub fn zshRc(
    buf: []u8,
    relay_port: u16,
    socket_addr: []const u8,
    startup_command: ?[]const u8,
) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    try w.print(
        \\# cmux remote session bootstrap — .zshrc
        \\
        \\# Source user's .zshrc.
        \\[ -f "$CMUX_REAL_ZDOTDIR/.zshrc" ] && source "$CMUX_REAL_ZDOTDIR/.zshrc"
        \\
        \\# Preserve real history location.
        \\export HISTFILE="${{CMUX_REAL_ZDOTDIR:-$HOME}}/.zsh_history"
        \\
        \\# cmux environment.
        \\export CMUX_SOCKET_PATH="{s}"
        \\export CMUX_RELAY_PORT="{d}"
        \\
        \\# Add cmux CLI to PATH if available.
        \\[ -d "$HOME/.cmux/bin" ] && export PATH="$HOME/.cmux/bin:$PATH"
        \\
    , .{ socket_addr, relay_port });

    if (startup_command) |cmd| {
        if (cmd.len > 0) {
            try w.print(
                \\# Startup command.
                \\{s}
                \\
            , .{cmd});
        }
    }

    return fbs.getWritten();
}

/// Generate the Zsh .zprofile content.
pub fn zshProfile(buf: []u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    try w.writeAll(
        \\# cmux remote session bootstrap — .zprofile
        \\[ -f "$CMUX_REAL_ZDOTDIR/.zprofile" ] && source "$CMUX_REAL_ZDOTDIR/.zprofile"
        \\
    );

    return fbs.getWritten();
}

/// Generate the Zsh .zlogin content.
pub fn zshLogin(buf: []u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    try w.writeAll(
        \\# cmux remote session bootstrap — .zlogin
        \\[ -f "$CMUX_REAL_ZDOTDIR/.zlogin" ] && source "$CMUX_REAL_ZDOTDIR/.zlogin"
        \\
    );

    return fbs.getWritten();
}

/// Generate the Bash .bashrc content for an isolated session.
pub fn bashRc(
    buf: []u8,
    relay_port: u16,
    socket_addr: []const u8,
    startup_command: ?[]const u8,
) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    try w.print(
        \\# cmux remote session bootstrap — .bashrc
        \\
        \\# Source user's login profile (first match wins).
        \\if [ -f "$HOME/.bash_profile" ]; then
        \\  source "$HOME/.bash_profile"
        \\elif [ -f "$HOME/.bash_login" ]; then
        \\  source "$HOME/.bash_login"
        \\elif [ -f "$HOME/.profile" ]; then
        \\  source "$HOME/.profile"
        \\fi
        \\
        \\# Source user's .bashrc.
        \\[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"
        \\
        \\# cmux environment.
        \\export CMUX_SOCKET_PATH="{s}"
        \\export CMUX_RELAY_PORT="{d}"
        \\
        \\# Add cmux CLI to PATH if available.
        \\[ -d "$HOME/.cmux/bin" ] && export PATH="$HOME/.cmux/bin:$PATH"
        \\
    , .{ socket_addr, relay_port });

    if (startup_command) |cmd| {
        if (cmd.len > 0) {
            try w.print(
                \\# Startup command.
                \\{s}
                \\
            , .{cmd});
        }
    }

    return fbs.getWritten();
}

/// Build the outer shell script that creates the isolated shell state
/// directory, writes dotfiles, and execs the login shell.
/// The script is meant to be base64-encoded and sent via SSH RemoteCommand.
pub fn buildInteractiveShellScript(
    buf: []u8,
    relay_port: u16,
    socket_addr: []const u8,
    startup_command: ?[]const u8,
) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    try w.print(
        \\#!/bin/sh
        \\# cmux remote interactive shell launcher
        \\CMUX_SHELL_DIR="$HOME/.cmux/relay/{d}.shell"
        \\mkdir -p "$CMUX_SHELL_DIR"
        \\
        \\export CMUX_SOCKET_PATH="{s}"
        \\export CMUX_RELAY_PORT="{d}"
        \\[ -d "$HOME/.cmux/bin" ] && export PATH="$HOME/.cmux/bin:$PATH"
        \\
        \\SHELL_NAME="$(basename "$SHELL")"
        \\case "$SHELL_NAME" in
        \\  zsh)
        \\    export CMUX_REAL_ZDOTDIR="${{ZDOTDIR:-$HOME}}"
        \\    export ZDOTDIR="$CMUX_SHELL_DIR"
        \\    # Write bootstrap dotfiles.
        \\    cat > "$CMUX_SHELL_DIR/.zshenv" << 'CMUX_EOF'
        \\[ -f "$CMUX_REAL_ZDOTDIR/.zshenv" ] && source "$CMUX_REAL_ZDOTDIR/.zshenv"
        \\CMUX_EOF
        \\    cat > "$CMUX_SHELL_DIR/.zshrc" << 'CMUX_EOF'
        \\[ -f "$CMUX_REAL_ZDOTDIR/.zshrc" ] && source "$CMUX_REAL_ZDOTDIR/.zshrc"
        \\export HISTFILE="${{CMUX_REAL_ZDOTDIR:-$HOME}}/.zsh_history"
        \\
    , .{ relay_port, socket_addr, relay_port });

    if (startup_command) |cmd| {
        if (cmd.len > 0) {
            try w.print("{s}\n", .{cmd});
        }
    }

    try w.writeAll(
        \\CMUX_EOF
        \\    exec "$SHELL" -l
        \\    ;;
        \\  bash)
        \\    exec "$SHELL" --rcfile "$CMUX_SHELL_DIR/.bashrc" -i
        \\    ;;
        \\  *)
        \\    exec "$SHELL" -l
        \\    ;;
        \\esac
        \\
    );

    return fbs.getWritten();
}
