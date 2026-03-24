const std = @import("std");
const Config = @import("../config/Config.zig");

const cmd = if (@import("build_options").cmux) "cmux" else "ghostty";

/// This is the associated Vim file as named by the variable.
pub const syntax = comptimeGenSyntax();
pub const ftdetect = ftdetect: {
    break :ftdetect
        \\" Vim filetype detect file
        \\" Language: Ghostty config file
        \\" Maintainer: Ghostty <https://github.com/ghostty-org/ghostty>
        \\"
        \\" THIS FILE IS AUTO-GENERATED
        \\
    ++ "au BufRead,BufNewFile */" ++ cmd ++ "/config,*/*." ++ cmd ++ "/config,*/" ++ cmd ++ "/themes/*,*." ++ cmd ++ " setf " ++ cmd ++ "\n";
};
pub const ftplugin = ftplugin: {
    break :ftplugin
        \\" Vim filetype plugin file
        \\" Language: Ghostty config file
        \\" Maintainer: Ghostty <https://github.com/ghostty-org/ghostty>
        \\"
        \\" THIS FILE IS AUTO-GENERATED
        \\
        \\if exists('b:did_ftplugin')
        \\  finish
        \\endif
        \\let b:did_ftplugin = 1
        \\
        \\setlocal commentstring=#\ %s
        \\setlocal iskeyword+=-
        \\
        \\" Use syntax keywords for completion
        \\setlocal omnifunc=syntaxcomplete#Complete
        \\
    ++ "\" Ask " ++ cmd ++ " to explain config keywords\n" ++
        "setlocal keywordprg=" ++ cmd ++ "\\ +explain-config\n" ++
        \\
        \\let b:undo_ftplugin = 'setl cms< isk< ofu< kp<'
        \\
    ++ "if !exists('current_compiler')\n" ++
        "  compiler " ++ cmd ++ "\n" ++
        "  let b:undo_ftplugin .= \" makeprg< errorformat<\"\n" ++
        \\endif
        \\
    ;
};
pub const compiler = compiler: {
    break :compiler
        \\" Vim compiler file
        \\" Language: Ghostty config file
        \\" Maintainer: Ghostty <https://github.com/ghostty-org/ghostty>
        \\"
        \\" THIS FILE IS AUTO-GENERATED
        \\
        \\if exists("current_compiler")
        \\  finish
        \\endif
        \\
    ++ "let current_compiler = \"" ++ cmd ++ "\"\n\n" ++
        "CompilerSet makeprg=" ++ cmd ++ "\\ +validate-config\\ --config-file=%:S\n" ++
        \\CompilerSet errorformat=%f:%l:%m,%m
        \\
    ;
};

/// Generates the syntax file at comptime.
fn comptimeGenSyntax() []const u8 {
    comptime {
        @setEvalBranchQuota(50000);
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try writeSyntax(&counter.writer);

        var buf: [counter.count]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try writeSyntax(&writer);
        const final = buf;
        return final[0..writer.end];
    }
}

/// Writes the syntax file to the given writer.
fn writeSyntax(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\" Vim syntax file
        \\" Language: Ghostty config file
        \\" Maintainer: Ghostty <https://github.com/ghostty-org/ghostty>
        \\"
        \\" THIS FILE IS AUTO-GENERATED
        \\
        \\if exists('b:current_syntax')
        \\  finish
        \\endif
        \\
    );
    try writer.writeAll("let b:current_syntax = '" ++ cmd ++ "'\n\n");
    try writer.writeAll(
        \\let s:cpo_save = &cpo
        \\set cpo&vim
        \\
    );
    try writer.writeAll("syn iskeyword @,48-57,-\nsyn keyword " ++ cmd ++ "ConfigKeyword");

    const config_fields = @typeInfo(Config).@"struct".fields;
    inline for (config_fields) |field| {
        if (field.name[0] == '_') continue;
        try writer.print("\n\t\\ {s}", .{field.name});
    }

    try writer.writeAll("\n\n" ++
        "syn match " ++ cmd ++ "ConfigComment /^\\s*#.*/ contains=@Spell\n\n" ++
        "hi def link " ++ cmd ++ "ConfigComment Comment\n" ++
        "hi def link " ++ cmd ++ "ConfigKeyword Keyword\n\n" ++
        \\let &cpo = s:cpo_save
        \\unlet s:cpo_save
        \\
    );
}

test {
    _ = syntax;
}
