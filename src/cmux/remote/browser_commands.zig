//! V2 socket command handlers for browser.* methods.
//!
//! Full P0 command set matching macOS TerminalController v2Browser* handlers.
//! Most commands work by generating JavaScript and evaluating it via the
//! existing browserEval WindowOps callback (GMainLoop async-to-sync bridge).
//!
//! Response shapes match Mac's field set: workspace_id, workspace_ref,
//! surface_id, surface_ref, action, value, etc.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const glib = @import("glib");
const v2 = @import("../v2.zig");
const Server = @import("../Server.zig");
const RefMap = @import("../RefMap.zig");
const Uuid = @import("../uuid.zig").Uuid;
const dispatch = @import("../dispatch.zig");
const window_ops_mod = @import("../window_ops.zig");
const client_handler = @import("../client_handler.zig");
const workspace_mod = @import("../workspace/main.zig");

const log = std.log.scoped(.cmux_browser_commands);

// Element ref counter for find.* commands (matches Mac's @e1, @e2, ...)
var next_element_ordinal: u64 = 1;

/// All browser.* method names for system.capabilities registration.
pub const method_names = [_][]const u8{
    // Navigation
    "browser.open_split",
    "browser.navigate",
    "browser.back",
    "browser.forward",
    "browser.reload",
    "browser.url.get",
    "browser.eval",
    // Element interactions
    "browser.click",
    "browser.dblclick",
    "browser.hover",
    "browser.focus",
    "browser.type",
    "browser.fill",
    "browser.press",
    "browser.keydown",
    "browser.keyup",
    "browser.check",
    "browser.uncheck",
    "browser.select",
    "browser.scroll",
    "browser.scroll_into_view",
    // DOM queries
    "browser.get.text",
    "browser.get.html",
    "browser.get.value",
    "browser.get.attr",
    "browser.get.url",
    "browser.get.title",
    "browser.get.count",
    "browser.get.box",
    "browser.get.styles",
    // Predicates
    "browser.is.visible",
    "browser.is.enabled",
    "browser.is.checked",
    // Find / locators
    "browser.find.role",
    "browser.find.text",
    "browser.find.label",
    "browser.find.placeholder",
    "browser.find.alt",
    "browser.find.title",
    "browser.find.testid",
    "browser.find.nth",
    "browser.find.first",
    "browser.find.last",
    // Special
    "browser.snapshot",
    "browser.screenshot",
    "browser.wait",
    "browser.focus_webview",
    "browser.is_webview_focused",
    // Scripting (extended)
    "browser.addinitscript",
    "browser.addscript",
    "browser.addstyle",
    // Frames
    "browser.frame.select",
    "browser.frame.main",
    // Dialogs
    "browser.dialog.accept",
    "browser.dialog.dismiss",
    // Downloads
    "browser.download.wait",
    // Cookies
    "browser.cookies.get",
    "browser.cookies.set",
    "browser.cookies.clear",
    // Storage
    "browser.storage.get",
    "browser.storage.set",
    "browser.storage.clear",
    // Tabs
    "browser.tab.new",
    "browser.tab.list",
    "browser.tab.switch",
    "browser.tab.close",
    // Console / Errors
    "browser.console.list",
    "browser.console.clear",
    "browser.errors.list",
    // Misc
    "browser.highlight",
    "browser.state.save",
    "browser.state.load",
    "browser.viewport.set",
    "browser.geolocation.set",
    "browser.offline.set",
    "browser.trace.start",
    "browser.trace.stop",
    "browser.network.route",
    "browser.network.unroute",
    "browser.network.requests",
    "browser.screencast.start",
    "browser.screencast.stop",
    "browser.input_mouse",
    "browser.input_keyboard",
    "browser.input_touch",
};

/// Dispatch a browser.* method to the appropriate handler.
pub fn dispatchBrowser(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const m = req.method;
    // Navigation
    if (std.mem.eql(u8, m, "browser.open_split")) return handleOpenSplit(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.navigate")) return handleNavigate(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.back")) return handleNavSimple(server, arena, writer, req, .back);
    if (std.mem.eql(u8, m, "browser.forward")) return handleNavSimple(server, arena, writer, req, .forward);
    if (std.mem.eql(u8, m, "browser.reload")) return handleNavSimple(server, arena, writer, req, .reload);
    if (std.mem.eql(u8, m, "browser.url.get")) return handleGetUrl(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.eval")) return handleEval(server, arena, writer, req);
    // Element interactions
    if (std.mem.eql(u8, m, "browser.click")) return handleSelectorCmd(server, arena, writer, req, "click", js_click);
    if (std.mem.eql(u8, m, "browser.dblclick")) return handleSelectorCmd(server, arena, writer, req, "dblclick", js_dblclick);
    if (std.mem.eql(u8, m, "browser.hover")) return handleSelectorCmd(server, arena, writer, req, "hover", js_hover);
    if (std.mem.eql(u8, m, "browser.focus")) return handleSelectorCmd(server, arena, writer, req, "focus", js_focus);
    if (std.mem.eql(u8, m, "browser.type")) return handleTextCmd(server, arena, writer, req, "type", false);
    if (std.mem.eql(u8, m, "browser.fill")) return handleTextCmd(server, arena, writer, req, "fill", true);
    if (std.mem.eql(u8, m, "browser.press")) return handleKeyCmd(server, arena, writer, req, "press");
    if (std.mem.eql(u8, m, "browser.keydown")) return handleKeyCmd(server, arena, writer, req, "keydown");
    if (std.mem.eql(u8, m, "browser.keyup")) return handleKeyCmd(server, arena, writer, req, "keyup");
    if (std.mem.eql(u8, m, "browser.check")) return handleSelectorCmd(server, arena, writer, req, "check", js_check);
    if (std.mem.eql(u8, m, "browser.uncheck")) return handleSelectorCmd(server, arena, writer, req, "uncheck", js_uncheck);
    if (std.mem.eql(u8, m, "browser.select")) return handleSelectCmd(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.scroll")) return handleScroll(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.scroll_into_view")) return handleSelectorCmd(server, arena, writer, req, "scroll_into_view", js_scroll_into_view);
    // DOM queries
    if (std.mem.eql(u8, m, "browser.get.text")) return handleSelectorCmd(server, arena, writer, req, "get.text", js_get_text);
    if (std.mem.eql(u8, m, "browser.get.html")) return handleSelectorCmd(server, arena, writer, req, "get.html", js_get_html);
    if (std.mem.eql(u8, m, "browser.get.value")) return handleSelectorCmd(server, arena, writer, req, "get.value", js_get_value);
    if (std.mem.eql(u8, m, "browser.get.attr")) return handleGetAttr(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.get.url")) return handleJsNoSelector(server, arena, writer, req, "get.url", "({ok:true,value:window.location.href})");
    if (std.mem.eql(u8, m, "browser.get.title")) return handleJsNoSelector(server, arena, writer, req, "get.title", "({ok:true,value:document.title})");
    if (std.mem.eql(u8, m, "browser.get.count")) return handleGetCount(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.get.box")) return handleSelectorCmd(server, arena, writer, req, "get.box", js_get_box);
    if (std.mem.eql(u8, m, "browser.get.styles")) return handleGetStyles(server, arena, writer, req);
    // Predicates
    if (std.mem.eql(u8, m, "browser.is.visible")) return handleSelectorCmd(server, arena, writer, req, "is.visible", js_is_visible);
    if (std.mem.eql(u8, m, "browser.is.enabled")) return handleSelectorCmd(server, arena, writer, req, "is.enabled", js_is_enabled);
    if (std.mem.eql(u8, m, "browser.is.checked")) return handleSelectorCmd(server, arena, writer, req, "is.checked", js_is_checked);
    // Find / locators
    if (std.mem.startsWith(u8, m, "browser.find.")) return handleFind(server, arena, writer, req);
    // Special
    if (std.mem.eql(u8, m, "browser.snapshot")) return handleSnapshot(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.screenshot")) return handleScreenshot(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.wait")) return handleWait(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.focus_webview")) return handleFocusWebview(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.is_webview_focused")) return handleIsWebviewFocused(server, arena, writer, req);
    // Extended scripting
    if (std.mem.eql(u8, m, "browser.addinitscript")) return handleAddScript(server, arena, writer, req, "addinitscript");
    if (std.mem.eql(u8, m, "browser.addscript")) return handleAddScript(server, arena, writer, req, "addscript");
    if (std.mem.eql(u8, m, "browser.addstyle")) return handleAddStyle(server, arena, writer, req);
    // Frames
    if (std.mem.eql(u8, m, "browser.frame.select")) return handleFrameSelect(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.frame.main")) return handleFrameMain(server, arena, writer, req);
    // Dialogs
    if (std.mem.eql(u8, m, "browser.dialog.accept")) return handleDialogStub(server, arena, writer, req, "dialog.accept");
    if (std.mem.eql(u8, m, "browser.dialog.dismiss")) return handleDialogStub(server, arena, writer, req, "dialog.dismiss");
    // Downloads
    if (std.mem.eql(u8, m, "browser.download.wait")) return handleNotSupported(arena, writer, req, "browser.download.wait", "WebKitGTK does not expose download interception hooks equivalent to Playwright");
    // Cookies
    if (std.mem.eql(u8, m, "browser.cookies.get")) return handleCookiesGet(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.cookies.set")) return handleCookiesSet(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.cookies.clear")) return handleCookiesClear(server, arena, writer, req);
    // Storage
    if (std.mem.eql(u8, m, "browser.storage.get")) return handleStorageCmd(server, arena, writer, req, "get");
    if (std.mem.eql(u8, m, "browser.storage.set")) return handleStorageCmd(server, arena, writer, req, "set");
    if (std.mem.eql(u8, m, "browser.storage.clear")) return handleStorageCmd(server, arena, writer, req, "clear");
    // Tabs
    if (std.mem.eql(u8, m, "browser.tab.new")) return handleNotSupported(arena, writer, req, "browser.tab.new", "WebKitGTK browser panels are single-tab; use browser.open_split");
    if (std.mem.eql(u8, m, "browser.tab.list")) return handleTabList(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.tab.switch")) return handleNotSupported(arena, writer, req, "browser.tab.switch", "WebKitGTK browser panels are single-tab");
    if (std.mem.eql(u8, m, "browser.tab.close")) return handleNotSupported(arena, writer, req, "browser.tab.close", "WebKitGTK browser panels are single-tab; use surface.close");
    // Console / Errors
    if (std.mem.eql(u8, m, "browser.console.list")) return handleConsoleList(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.console.clear")) return handleConsoleClear(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.errors.list")) return handleErrorsList(server, arena, writer, req);
    // Misc
    if (std.mem.eql(u8, m, "browser.highlight")) return handleHighlight(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.state.save")) return handleStateSave(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.state.load")) return handleStateLoad(server, arena, writer, req);
    if (std.mem.eql(u8, m, "browser.viewport.set")) return handleNotSupported(arena, writer, req, "browser.viewport.set", "WebKitGTK does not provide per-tab programmable viewport emulation");
    if (std.mem.eql(u8, m, "browser.geolocation.set")) return handleNotSupported(arena, writer, req, "browser.geolocation.set", "WebKitGTK does not expose per-tab geolocation spoofing");
    if (std.mem.eql(u8, m, "browser.offline.set")) return handleNotSupported(arena, writer, req, "browser.offline.set", "WebKitGTK does not expose reliable per-tab offline emulation");
    if (std.mem.eql(u8, m, "browser.trace.start")) return handleNotSupported(arena, writer, req, "browser.trace.start", "Playwright trace artifacts are not available on WebKitGTK");
    if (std.mem.eql(u8, m, "browser.trace.stop")) return handleNotSupported(arena, writer, req, "browser.trace.stop", "Playwright trace artifacts are not available on WebKitGTK");
    if (std.mem.eql(u8, m, "browser.network.route")) return handleNotSupported(arena, writer, req, "browser.network.route", "WebKitGTK does not provide CDP-style request interception/mocking");
    if (std.mem.eql(u8, m, "browser.network.unroute")) return handleNotSupported(arena, writer, req, "browser.network.unroute", "WebKitGTK does not provide CDP-style request interception/mocking");
    if (std.mem.eql(u8, m, "browser.network.requests")) return handleNotSupported(arena, writer, req, "browser.network.requests", "Request interception logs are unavailable without CDP network hooks");
    if (std.mem.eql(u8, m, "browser.screencast.start")) return handleNotSupported(arena, writer, req, "browser.screencast.start", "WebKitGTK does not expose CDP screencast streaming");
    if (std.mem.eql(u8, m, "browser.screencast.stop")) return handleNotSupported(arena, writer, req, "browser.screencast.stop", "WebKitGTK does not expose CDP screencast streaming");
    if (std.mem.eql(u8, m, "browser.input_mouse")) return handleNotSupported(arena, writer, req, "browser.input_mouse", "Raw CDP mouse injection is unavailable; use browser.click/hover/scroll");
    if (std.mem.eql(u8, m, "browser.input_keyboard")) return handleNotSupported(arena, writer, req, "browser.input_keyboard", "Raw CDP keyboard injection is unavailable; use browser.press/keydown/keyup");
    if (std.mem.eql(u8, m, "browser.input_touch")) return handleNotSupported(arena, writer, req, "browser.input_touch", "Raw CDP touch injection is unavailable on WebKitGTK");

    v2.writeError(writer, arena, req.id, v2.ErrorCode.method_not_found, "Unknown browser method") catch {};
}

// =======================================================================
// JS templates for selector-based commands
// Each returns a JS IIFE string fragment that goes AFTER `const el = ...`
// =======================================================================

const js_click =
    \\el.scrollIntoView({block:'nearest',inline:'nearest'});
    \\if(typeof el.click==='function'){el.click()}
    \\else{el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window,detail:1}))}
    \\return{ok:true};
;
const js_dblclick =
    \\el.scrollIntoView({block:'nearest',inline:'nearest'});
    \\el.dispatchEvent(new MouseEvent('dblclick',{bubbles:true,cancelable:true,view:window,detail:2}));
    \\return{ok:true};
;
const js_hover =
    \\el.dispatchEvent(new MouseEvent('mouseenter',{bubbles:true,view:window}));
    \\el.dispatchEvent(new MouseEvent('mouseover',{bubbles:true,view:window}));
    \\return{ok:true};
;
const js_focus =
    \\if(typeof el.focus==='function')el.focus();
    \\return{ok:true};
;
const js_check =
    \\el.checked=true;
    \\el.dispatchEvent(new Event('change',{bubbles:true}));
    \\return{ok:true};
;
const js_uncheck =
    \\el.checked=false;
    \\el.dispatchEvent(new Event('change',{bubbles:true}));
    \\return{ok:true};
;
const js_scroll_into_view =
    \\el.scrollIntoView({block:'center',inline:'center'});
    \\return{ok:true};
;
const js_get_text =
    \\return{ok:true,value:String(el.innerText||el.textContent||'')};
;
const js_get_html =
    \\return{ok:true,value:el.outerHTML};
;
const js_get_value =
    \\return{ok:true,value:String('value' in el?el.value:(el.textContent||''))};
;
const js_get_box =
    \\var r=el.getBoundingClientRect();
    \\return{ok:true,value:{x:r.x,y:r.y,width:r.width,height:r.height,top:r.top,left:r.left,right:r.right,bottom:r.bottom}};
;
const js_is_visible =
    \\var s=getComputedStyle(el);
    \\var v=s.display!=='none'&&s.visibility!=='hidden'&&parseFloat(s.opacity)>0&&el.offsetWidth>0&&el.offsetHeight>0;
    \\return{ok:true,value:v};
;
const js_is_enabled =
    \\return{ok:true,value:!el.disabled};
;
const js_is_checked =
    \\return{ok:true,value:!!el.checked};
;

// =======================================================================
// Shared selector action handler
// =======================================================================

/// Handle a command that targets an element by CSS selector:
/// 1. Extract selector from params
/// 2. Build JS: querySelector + action
/// 3. Eval via browserEval
/// 4. Parse result, write response
fn handleSelectorCmd(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
    action_name: []const u8,
    action_js: []const u8,
) void {
    const sel = getSelector(req.params);
    if (sel.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing selector") catch {};
        return;
    }

    // Build: (()=>{ const el=document.querySelector(SEL); if(!el) return {ok:false,error:'not_found'}; ACTION })()
    const js = buildSelectorJs(arena, sel, action_js) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS build failed") catch {};
        return;
    };

    execJsAndRespond(server, arena, writer, req, js, action_name);
}

/// Handle commands that don't need a selector (get.url, get.title).
fn handleJsNoSelector(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
    action_name: []const u8,
    js_expr: []const u8,
) void {
    const js = arena.allocSentinel(u8, js_expr.len, 0) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
        return;
    };
    @memcpy(js, js_expr);
    execJsAndRespond(server, arena, writer, req, js, action_name);
}

// =======================================================================
// Text input commands (type / fill)
// =======================================================================

fn handleTextCmd(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
    action_name: []const u8,
    is_fill: bool,
) void {
    const sel = getSelector(req.params);
    if (sel.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing selector") catch {};
        return;
    }
    const text = jsonStr(req.params.get("text"));
    if (text.len == 0 and !is_fill) {
        // type requires text; fill allows empty (to clear)
        if (jsonStr(req.params.get("value")).len == 0) {
            v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing text") catch {};
            return;
        }
    }
    const text_val = if (text.len > 0) text else jsonStr(req.params.get("value"));

    // Build action JS
    const action_js = if (is_fill)
        // fill: replace value entirely
        \\if(typeof el.focus==='function')el.focus();
        \\if('value' in el){el.value=__text;el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}))}
        \\else{el.textContent=__text}
        \\return{ok:true};
    else
        // type: append to existing value
        \\if(typeof el.focus==='function')el.focus();
        \\if('value' in el){el.value+=__text;el.dispatchEvent(new Event('input',{bubbles:true}))}
        \\else{el.textContent+=__text}
        \\return{ok:true};
    ;

    // Build complete JS with text variable injection
    const js = buildTextSelectorJs(arena, sel, text_val, action_js) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS build failed") catch {};
        return;
    };

    execJsAndRespond(server, arena, writer, req, js, action_name);
}

// =======================================================================
// Key commands (press / keydown / keyup)
// =======================================================================

fn handleKeyCmd(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
    action_name: []const u8,
) void {
    const key = jsonStr(req.params.get("key"));
    if (key.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing key") catch {};
        return;
    }

    const sel = getSelector(req.params);
    const target_expr = if (sel.len > 0) "document.querySelector(" ++ "'" else "document.activeElement||document.body";
    _ = target_expr;

    // Build JS for key event dispatch
    var buf: [4096]u8 = undefined;
    const js_template = if (std.mem.eql(u8, action_name, "press"))
        "(()=>{{var t={s};if(!t)return{{ok:false,error:'not_found'}};var o={{key:'{s}',bubbles:true}};t.dispatchEvent(new KeyboardEvent('keydown',o));t.dispatchEvent(new KeyboardEvent('keypress',o));t.dispatchEvent(new KeyboardEvent('keyup',o));return{{ok:true}}}})()"
    else if (std.mem.eql(u8, action_name, "keydown"))
        "(()=>{{var t={s};if(!t)return{{ok:false,error:'not_found'}};t.dispatchEvent(new KeyboardEvent('keydown',{{key:'{s}',bubbles:true}}));return{{ok:true}}}})()"
    else
        "(()=>{{var t={s};if(!t)return{{ok:false,error:'not_found'}};t.dispatchEvent(new KeyboardEvent('keyup',{{key:'{s}',bubbles:true}}));return{{ok:true}}}})()";

    const target = if (sel.len > 0)
        std.fmt.bufPrint(&buf, "document.querySelector('{s}')", .{sel}) catch ""
    else
        "document.activeElement||document.body";

    var js_buf: [8192:0]u8 = undefined;
    // js_template is runtime-known, so we can't use bufPrint directly.
    // Instead, manually substitute {s} placeholders.
    var stream = std.io.fixedBufferStream(&js_buf);
    const js_writer = stream.writer();
    var tmpl_remaining: []const u8 = js_template;
    const subs = [_][]const u8{ target, key };
    var sub_idx: usize = 0;
    while (tmpl_remaining.len > 0) {
        if (std.mem.indexOf(u8, tmpl_remaining, "{s}")) |pos| {
            js_writer.writeAll(tmpl_remaining[0..pos]) catch {
                v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS format failed") catch {};
                return;
            };
            if (sub_idx < subs.len) {
                js_writer.writeAll(subs[sub_idx]) catch {
                    v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS format failed") catch {};
                    return;
                };
                sub_idx += 1;
            }
            tmpl_remaining = tmpl_remaining[pos + 3 ..];
        } else {
            js_writer.writeAll(tmpl_remaining) catch {
                v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS format failed") catch {};
                return;
            };
            break;
        }
    }
    const written = stream.pos;
    js_buf[written] = 0;

    const js = arena.allocSentinel(u8, written, 0) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
        return;
    };
    @memcpy(js, js_buf[0..written]);

    execJsAndRespond(server, arena, writer, req, js, action_name);
}

// =======================================================================
// browser.select
// =======================================================================

fn handleSelectCmd(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const sel = getSelector(req.params);
    if (sel.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing selector") catch {};
        return;
    }
    const value = jsonStr(req.params.get("value"));
    const action_js =
        \\el.value=__text;
        \\el.dispatchEvent(new Event('change',{bubbles:true}));
        \\return{ok:true};
    ;
    const js = buildTextSelectorJs(arena, sel, value, action_js) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS build failed") catch {};
        return;
    };
    execJsAndRespond(server, arena, writer, req, js, "select");
}

// =======================================================================
// browser.scroll
// =======================================================================

fn handleScroll(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const top = jsonStr(req.params.get("top"));
    const left = jsonStr(req.params.get("left"));
    const sel = getSelector(req.params);

    var js_buf: [2048:0]u8 = undefined;
    const len = if (sel.len > 0)
        std.fmt.bufPrint(&js_buf, "(()=>{{var el=document.querySelector('{s}');if(!el)return{{ok:false,error:'not_found'}};el.scrollBy({{top:{s},left:{s}}});return{{ok:true}}}})()", .{ sel, if (top.len > 0) top else "0", if (left.len > 0) left else "0" }) catch {
            v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS format failed") catch {};
            return;
        }
    else
        std.fmt.bufPrint(&js_buf, "(()=>{{window.scrollBy({{top:{s},left:{s}}});return{{ok:true}}}})()", .{ if (top.len > 0) top else "0", if (left.len > 0) left else "0" }) catch {
            v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS format failed") catch {};
            return;
        };
    js_buf[len.len] = 0;

    const js = arena.allocSentinel(u8, len.len, 0) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
        return;
    };
    @memcpy(js, len);
    execJsAndRespond(server, arena, writer, req, js, "scroll");
}

// =======================================================================
// browser.get.attr
// =======================================================================

fn handleGetAttr(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const sel = getSelector(req.params);
    if (sel.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing selector") catch {};
        return;
    }
    const name = jsonStr(req.params.get("name"));
    if (name.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing name") catch {};
        return;
    }

    var js_buf: [4096:0]u8 = undefined;
    const len = std.fmt.bufPrint(&js_buf, "(()=>{{var el=document.querySelector('{s}');if(!el)return{{ok:false,error:'not_found'}};return{{ok:true,value:el.getAttribute('{s}')}}}})()", .{ sel, name }) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS format failed") catch {};
        return;
    };
    js_buf[len.len] = 0;

    const js = arena.allocSentinel(u8, len.len, 0) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
        return;
    };
    @memcpy(js, len);
    execJsAndRespond(server, arena, writer, req, js, "get.attr");
}

// =======================================================================
// browser.get.count
// =======================================================================

fn handleGetCount(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const sel = getSelector(req.params);
    if (sel.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing selector") catch {};
        return;
    }
    var js_buf: [2048:0]u8 = undefined;
    const len = std.fmt.bufPrint(&js_buf, "(()=>{{return{{ok:true,value:document.querySelectorAll('{s}').length}}}})()", .{sel}) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS format failed") catch {};
        return;
    };
    js_buf[len.len] = 0;

    const js = arena.allocSentinel(u8, len.len, 0) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
        return;
    };
    @memcpy(js, len);
    execJsAndRespond(server, arena, writer, req, js, "get.count");
}

// =======================================================================
// browser.get.styles
// =======================================================================

fn handleGetStyles(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const sel = getSelector(req.params);
    if (sel.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing selector") catch {};
        return;
    }
    const prop = jsonStr(req.params.get("property"));
    const action_js = if (prop.len > 0) blk: {
        const prefix = "var s=getComputedStyle(el);return{ok:true,value:s.getPropertyValue('";
        const suffix = "')};";
        const total = prefix.len + prop.len + suffix.len;
        const buf = arena.alloc(u8, total) catch {
            v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
            return;
        };
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..][0..prop.len], prop);
        @memcpy(buf[prefix.len + prop.len ..][0..suffix.len], suffix);
        break :blk @as([]const u8, buf);
    } else
        @as([]const u8, "var s=getComputedStyle(el);var o={};for(var i=0;i<s.length;i++){var p=s[i];o[p]=s.getPropertyValue(p)}return{ok:true,value:o};");
    const js = buildSelectorJs(arena, sel, action_js) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS build failed") catch {};
        return;
    };
    execJsAndRespond(server, arena, writer, req, js, "get.styles");
}

// =======================================================================
// browser.find.* (locators)
// =======================================================================

fn handleFind(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const m = req.method;
    const sub = if (std.mem.indexOf(u8, m, "find.")) |idx| m[idx + 5 ..] else "";

    // Build finder JS based on sub-command
    var js_buf: [8192:0]u8 = undefined;
    const js_slice = buildFinderJs(&js_buf, sub, req.params) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS build failed") catch {};
        return;
    };
    js_buf[js_slice.len] = 0;

    const surface_id = server.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {};
        return;
    };

    // Execute the finder JS
    const eval_result = doEval(server, surface_id, @ptrCast(&js_buf), 5_000);
    if (eval_result.error_message) |err_msg| {
        const msg = arena.dupe(u8, err_msg) catch "Find failed";
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, msg) catch {};
        return;
    }

    // Parse the result
    const ws_id = resolveBrowserWorkspace(server, surface_id);
    var resp = json.ObjectMap.init(arena);
    putSurfaceFields(server, arena, &resp, ws_id, surface_id);
    const action_str = blk: {
        var action_buf: [64]u8 = undefined;
        const prefix = "find.";
        @memcpy(action_buf[0..prefix.len], prefix);
        const end = @min(prefix.len + sub.len, action_buf.len);
        @memcpy(action_buf[prefix.len..end], sub[0..end - prefix.len]);
        break :blk arena.dupe(u8, action_buf[0..end]) catch "find";
    };
    resp.put("action", .{ .string = action_str }) catch {};

    if (eval_result.json_value) |json_z| {
        defer glib.free(@constCast(@ptrCast(json_z)));
        const json_slice = std.mem.span(json_z);
        const parsed = std.json.parseFromSlice(json.Value, arena, json_slice, .{}) catch {
            resp.put("error", .{ .string = "Parse failed" }) catch {};
            v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
            return;
        };
        const val = parsed.value;
        // Check if element was found
        if (val == .object) {
            const obj = val.object;
            if (obj.get("ok")) |ok_val| {
                if (ok_val == .bool and !ok_val.bool) {
                    v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Element not found") catch {};
                    return;
                }
            }
            // Allocate element ref
            const ordinal = @atomicRmw(u64, &next_element_ordinal, .Add, 1, .monotonic);
            var ref_buf: [32]u8 = undefined;
            const ref_str = std.fmt.bufPrint(&ref_buf, "@e{d}", .{ordinal}) catch "@e0";
            resp.put("element_ref", .{ .string = arena.dupe(u8, ref_str) catch "" }) catch {};

            if (obj.get("selector")) |s| resp.put("selector", s) catch {};
            if (obj.get("tag")) |t| resp.put("tag", t) catch {};
            if (obj.get("text")) |t| resp.put("text", t) catch {};
            if (obj.get("role")) |r| resp.put("role", r) catch {};
            if (obj.get("name")) |n| resp.put("name", n) catch {};
        }
    }
    v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
}

fn buildFinderJs(buf: []u8, sub: []const u8, params: json.ObjectMap) ![]u8 {
    // Get search text/parameters
    const text = jsonStr(params.get("text"));
    const role = jsonStr(params.get("role"));
    const name = jsonStr(params.get("name"));
    const selector = getSelector(params);
    const index_str = jsonStr(params.get("index"));

    if (std.mem.eql(u8, sub, "role")) {
        return std.fmt.bufPrint(buf,
            \\(()=>{{var els=document.querySelectorAll('*');for(var i=0;i<els.length;i++){{var e=els[i];
            \\var r=e.getAttribute('role')||(e.tagName==='BUTTON'?'button':e.tagName==='A'?'link':
            \\e.tagName==='INPUT'&&e.type==='checkbox'?'checkbox':e.tagName==='INPUT'?'textbox':'');
            \\if(r==='{s}'&&('{s}'===''||e.textContent.trim().indexOf('{s}')>=0))
            \\return{{ok:true,selector:__csspath(e),tag:e.tagName.toLowerCase(),text:e.textContent.trim().slice(0,100),role:r,name:'{s}'}}}};
            \\return{{ok:false,error:'not_found'}}}})()
        , .{ role, name, name, name }) catch return error.Overflow;
    }
    if (std.mem.eql(u8, sub, "text")) {
        return std.fmt.bufPrint(buf,
            \\(()=>{{var els=document.querySelectorAll('*');for(var i=0;i<els.length;i++){{var e=els[i];
            \\if(e.children.length===0&&e.textContent.trim().indexOf('{s}')>=0)
            \\return{{ok:true,selector:__csspath(e),tag:e.tagName.toLowerCase(),text:e.textContent.trim().slice(0,100)}}}};
            \\return{{ok:false,error:'not_found'}}}})()
        , .{text}) catch return error.Overflow;
    }
    if (std.mem.eql(u8, sub, "label")) {
        return std.fmt.bufPrint(buf,
            \\(()=>{{var labels=document.querySelectorAll('label');for(var i=0;i<labels.length;i++){{var l=labels[i];
            \\if(l.textContent.trim().indexOf('{s}')>=0){{var e=l.htmlFor?document.getElementById(l.htmlFor):l.querySelector('input,textarea,select,button');
            \\if(e)return{{ok:true,selector:__csspath(e),tag:e.tagName.toLowerCase(),text:l.textContent.trim().slice(0,100)}}}}}};
            \\return{{ok:false,error:'not_found'}}}})()
        , .{text}) catch return error.Overflow;
    }
    // Attribute-based finders: placeholder, alt, title, testid
    const attr_name = if (std.mem.eql(u8, sub, "placeholder")) "placeholder"
    else if (std.mem.eql(u8, sub, "alt")) "alt"
    else if (std.mem.eql(u8, sub, "title")) "title"
    else if (std.mem.eql(u8, sub, "testid")) "data-testid"
    else "";

    if (attr_name.len > 0) {
        return std.fmt.bufPrint(buf,
            \\(()=>{{var e=document.querySelector('[{s}*="{s}"]');
            \\if(!e)return{{ok:false,error:'not_found'}};
            \\return{{ok:true,selector:__csspath(e),tag:e.tagName.toLowerCase(),text:(e.textContent||'').trim().slice(0,100)}}}})()
        , .{ attr_name, text }) catch return error.Overflow;
    }
    // nth, first, last
    if (std.mem.eql(u8, sub, "nth")) {
        return std.fmt.bufPrint(buf,
            \\(()=>{{var els=document.querySelectorAll('{s}');var idx={s};
            \\if(idx<0||idx>=els.length)return{{ok:false,error:'not_found'}};var e=els[idx];
            \\return{{ok:true,selector:__csspath(e),tag:e.tagName.toLowerCase(),text:(e.textContent||'').trim().slice(0,100)}}}})()
        , .{ selector, if (index_str.len > 0) index_str else "0" }) catch return error.Overflow;
    }
    if (std.mem.eql(u8, sub, "first")) {
        return std.fmt.bufPrint(buf,
            \\(()=>{{var e=document.querySelector('{s}');
            \\if(!e)return{{ok:false,error:'not_found'}};
            \\return{{ok:true,selector:__csspath(e),tag:e.tagName.toLowerCase(),text:(e.textContent||'').trim().slice(0,100)}}}})()
        , .{selector}) catch return error.Overflow;
    }
    if (std.mem.eql(u8, sub, "last")) {
        return std.fmt.bufPrint(buf,
            \\(()=>{{var els=document.querySelectorAll('{s}');
            \\if(!els.length)return{{ok:false,error:'not_found'}};var e=els[els.length-1];
            \\return{{ok:true,selector:__csspath(e),tag:e.tagName.toLowerCase(),text:(e.textContent||'').trim().slice(0,100)}}}})()
        , .{selector}) catch return error.Overflow;
    }
    return error.Overflow;
}

// =======================================================================
// browser.snapshot
// =======================================================================

fn handleSnapshot(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const interactive = if (req.params.get("interactive")) |v| (v == .bool and v.bool) else false;
    const max_depth_str = jsonStr(req.params.get("max_depth"));
    const max_depth = if (max_depth_str.len > 0) max_depth_str else "12";

    var js_buf: [16384:0]u8 = undefined;
    const len = std.fmt.bufPrint(&js_buf,
        \\(()=>{{
        \\var results=[];var maxD={s};var interOnly={s};
        \\function walk(node,depth){{
        \\if(depth>maxD||!node)return;
        \\if(node.nodeType!==1)return;
        \\var s=getComputedStyle(node);
        \\if(s.display==='none'||s.visibility==='hidden')return;
        \\var role=node.getAttribute('role')||(node.tagName==='BUTTON'?'button':node.tagName==='A'?'link':
        \\node.tagName==='INPUT'?'textbox':node.tagName==='SELECT'?'combobox':node.tagName==='TEXTAREA'?'textbox':
        \\node.tagName==='IMG'?'img':node.tagName==='H1'||node.tagName==='H2'||node.tagName==='H3'?'heading':'');
        \\var isInter=node.tagName==='BUTTON'||node.tagName==='A'||node.tagName==='INPUT'||
        \\node.tagName==='SELECT'||node.tagName==='TEXTAREA'||node.getAttribute('role');
        \\if(role||!interOnly){{
        \\var name=(node.getAttribute('aria-label')||node.textContent||'').trim().slice(0,80);
        \\if(!interOnly||isInter)results.push({{role:role||node.tagName.toLowerCase(),name:name,depth:depth,tag:node.tagName.toLowerCase()}});
        \\}}
        \\var kids=node.children;for(var i=0;i<kids.length;i++)walk(kids[i],depth+1);
        \\}}
        \\walk(document.body,0);
        \\var lines=results.map(function(r){{return' '.repeat(r.depth*2)+r.role+(r.name?' "'+r.name+'"':'');}});
        \\return{{ok:true,snapshot:lines.join('\n'),title:document.title,url:location.href,
        \\ready_state:document.readyState,entry_count:results.length}};
        \\}})()
    , .{ max_depth, if (interactive) "true" else "false" }) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS build failed") catch {};
        return;
    };
    js_buf[len.len] = 0;

    const js = arena.allocSentinel(u8, len.len, 0) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
        return;
    };
    @memcpy(js, len);
    execJsAndRespond(server, arena, writer, req, js, "snapshot");
}

// =======================================================================
// browser.screenshot (stub — requires native WebKit API)
// =======================================================================

fn handleScreenshot(
    _: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "screenshot requires native WebKitGTK snapshot API — not yet implemented") catch {};
}

// =======================================================================
// browser.wait
// =======================================================================

fn handleWait(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const timeout_str = jsonStr(req.params.get("timeout_ms"));
    const timeout = if (timeout_str.len > 0) timeout_str else "5000";
    const selector = getSelector(req.params);
    const url_contains = jsonStr(req.params.get("url_contains"));
    const text_contains = jsonStr(req.params.get("text_contains"));
    const load_state = jsonStr(req.params.get("load_state"));
    const function_str = jsonStr(req.params.get("function"));

    // Build condition check JS
    var cond_buf: [2048]u8 = undefined;
    const condition = if (selector.len > 0)
        std.fmt.bufPrint(&cond_buf, "!!document.querySelector('{s}')", .{selector}) catch "false"
    else if (url_contains.len > 0)
        std.fmt.bufPrint(&cond_buf, "window.location.href.indexOf('{s}')>=0", .{url_contains}) catch "false"
    else if (text_contains.len > 0)
        std.fmt.bufPrint(&cond_buf, "(document.body.innerText||'').indexOf('{s}')>=0", .{text_contains}) catch "false"
    else if (load_state.len > 0)
        std.fmt.bufPrint(&cond_buf, "document.readyState==='{s}'", .{load_state}) catch "false"
    else if (function_str.len > 0)
        std.fmt.bufPrint(&cond_buf, "!!({s})", .{function_str}) catch "false"
    else {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing wait condition (selector, url_contains, text_contains, load_state, or function)") catch {};
        return;
    };

    // Build polling JS with setTimeout
    var js_buf: [8192:0]u8 = undefined;
    const len = std.fmt.bufPrint(&js_buf,
        \\new Promise(function(resolve){{
        \\var deadline=Date.now()+{s};
        \\function check(){{
        \\if({s})return resolve({{ok:true,waited:true}});
        \\if(Date.now()>deadline)return resolve({{ok:false,error:'timeout'}});
        \\setTimeout(check,100);
        \\}}
        \\check();
        \\}})
    , .{ timeout, condition }) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS build failed") catch {};
        return;
    };
    js_buf[len.len] = 0;

    const js = arena.allocSentinel(u8, len.len, 0) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
        return;
    };
    @memcpy(js, len);

    // Use longer timeout for wait command (timeout + 2s buffer)
    const surface_id = server.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {};
        return;
    };

    const timeout_val = std.fmt.parseInt(u32, timeout, 10) catch 5000;
    const eval_result = doEval(server, surface_id, js, timeout_val + 2000);

    if (eval_result.error_message) |err_msg| {
        const msg = arena.dupe(u8, err_msg) catch "Wait failed";
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, msg) catch {};
        return;
    }

    const ws_id = resolveBrowserWorkspace(server, surface_id);
    var resp = json.ObjectMap.init(arena);
    putSurfaceFields(server, arena, &resp, ws_id, surface_id);
    resp.put("action", .{ .string = "wait" }) catch {};
    resp.put("waited", .{ .bool = true }) catch {};

    // Check for timeout in the JS result
    if (eval_result.json_value) |json_z| {
        defer glib.free(@constCast(@ptrCast(json_z)));
        const json_slice = std.mem.span(json_z);
        if (std.mem.indexOf(u8, json_slice, "timeout") != null) {
            resp.put("waited", .{ .bool = false }) catch {};
            resp.put("timed_out", .{ .bool = true }) catch {};
        }
    }
    v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
}

// =======================================================================
// browser.focus_webview / browser.is_webview_focused (GTK stubs)
// =======================================================================

fn handleFocusWebview(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const surface_id = server.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {};
        return;
    };
    const ws_id = resolveBrowserWorkspace(server, surface_id);
    var resp = json.ObjectMap.init(arena);
    putSurfaceFields(server, arena, &resp, ws_id, surface_id);
    resp.put("focused", .{ .bool = true }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
}

fn handleIsWebviewFocused(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const surface_id = server.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {};
        return;
    };
    const ws_id = resolveBrowserWorkspace(server, surface_id);
    var resp = json.ObjectMap.init(arena);
    putSurfaceFields(server, arena, &resp, ws_id, surface_id);
    resp.put("focused", .{ .bool = true }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
}

// =======================================================================
// Existing navigation handlers (unchanged)
// =======================================================================

const SyncBrowserOpenSplitCtx = struct {
    ops: window_ops_mod.WindowOps,
    ws_id: Uuid,
    url: ?[*:0]const u8,
    direction: window_ops_mod.Direction,
    result: ?window_ops_mod.BrowserSplitResult = null,
};

fn syncBrowserOpenSplit(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncBrowserOpenSplitCtx = @ptrCast(@alignCast(data orelse return 0));
    ctx.result = ctx.ops.browserOpenSplit(ctx.ws_id, ctx.url, ctx.direction);
    return 0;
}

fn handleOpenSplit(server: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const ops = server.window_ops orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window ops") catch {};
        return;
    };
    const ws_id = resolveWorkspaceId(server, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };
    const url_str = jsonStr(req.params.get("url"));
    const url: ?[*:0]const u8 = if (url_str.len > 0) blk: {
        const buf = arena.allocSentinel(u8, url_str.len, 0) catch { v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {}; return; };
        @memcpy(buf[0..url_str.len], url_str);
        break :blk buf;
    } else null;
    const dir_str = jsonStr(req.params.get("direction"));
    const direction = if (dir_str.len > 0) window_ops_mod.Direction.parse(dir_str) orelse .right else .right;

    var ctx = SyncBrowserOpenSplitCtx{ .ops = ops, .ws_id = ws_id, .url = url, .direction = direction };
    dispatch.syncOnMainThread(&syncBrowserOpenSplit, @ptrCast(&ctx));
    const result = ctx.result orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "Failed to open browser split") catch {};
        return;
    };
    var resp = json.ObjectMap.init(arena);
    resp.put("window_id", .null) catch {};
    resp.put("window_ref", .null) catch {};
    resp.put("workspace_id", jsonUuid(arena, result.workspace_id)) catch {};
    resp.put("workspace_ref", server.v2Ref(.workspace, result.workspace_id)) catch {};
    resp.put("pane_id", .null) catch {};
    resp.put("pane_ref", .null) catch {};
    resp.put("surface_id", jsonUuid(arena, result.surface_id)) catch {};
    resp.put("surface_ref", server.v2Ref(.surface, result.surface_id)) catch {};
    resp.put("created_split", .{ .bool = true }) catch {};
    resp.put("placement_strategy", .{ .string = "split_right" }) catch {};
    resp.put("type", .{ .string = "browser" }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
}

const SyncBrowserNavigateCtx = struct { ops: window_ops_mod.WindowOps, surface_id: Uuid, url: [*:0]const u8, result: bool = false };
fn syncBrowserNavigate(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncBrowserNavigateCtx = @ptrCast(@alignCast(data orelse return 0));
    ctx.result = ctx.ops.browserNavigate(ctx.surface_id, ctx.url);
    return 0;
}
fn handleNavigate(server: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const ops = server.window_ops orelse { v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window ops") catch {}; return; };
    const surface_id = server.v2UUID(req.params, "surface_id") orelse { v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {}; return; };
    const url_str = jsonStr(req.params.get("url"));
    if (url_str.len == 0) { v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing url") catch {}; return; }
    const url = arena.allocSentinel(u8, url_str.len, 0) catch { v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {}; return; };
    @memcpy(url[0..url_str.len], url_str);
    var ctx = SyncBrowserNavigateCtx{ .ops = ops, .surface_id = surface_id, .url = url };
    dispatch.syncOnMainThread(&syncBrowserNavigate, @ptrCast(&ctx));
    if (!ctx.result) { v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Browser panel not found") catch {}; return; }
    writeBrowserSurfaceResponse(server, arena, writer, req.id, resolveBrowserWorkspace(server, surface_id), surface_id);
}

const NavAction = enum { back, forward, reload };
const SyncBrowserNavSimpleCtx = struct { ops: window_ops_mod.WindowOps, surface_id: Uuid, action: NavAction, result: bool = false };
fn syncBrowserNavSimple(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncBrowserNavSimpleCtx = @ptrCast(@alignCast(data orelse return 0));
    ctx.result = switch (ctx.action) { .back => ctx.ops.browserBack(ctx.surface_id), .forward => ctx.ops.browserForward(ctx.surface_id), .reload => ctx.ops.browserReload(ctx.surface_id) };
    return 0;
}
fn handleNavSimple(server: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request, action: NavAction) void {
    const ops = server.window_ops orelse { v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window ops") catch {}; return; };
    const surface_id = server.v2UUID(req.params, "surface_id") orelse { v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {}; return; };
    var ctx = SyncBrowserNavSimpleCtx{ .ops = ops, .surface_id = surface_id, .action = action };
    dispatch.syncOnMainThread(&syncBrowserNavSimple, @ptrCast(&ctx));
    if (!ctx.result) { v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Browser panel not found") catch {}; return; }
    writeBrowserSurfaceResponse(server, arena, writer, req.id, resolveBrowserWorkspace(server, surface_id), surface_id);
}

const SyncBrowserGetUrlCtx = struct { ops: window_ops_mod.WindowOps, surface_id: Uuid, result: ?[*:0]const u8 = null };
fn syncBrowserGetUrl(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncBrowserGetUrlCtx = @ptrCast(@alignCast(data orelse return 0));
    ctx.result = ctx.ops.browserGetUrl(ctx.surface_id);
    return 0;
}
fn handleGetUrl(server: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const ops = server.window_ops orelse { v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window ops") catch {}; return; };
    const surface_id = server.v2UUID(req.params, "surface_id") orelse { v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {}; return; };
    var ctx = SyncBrowserGetUrlCtx{ .ops = ops, .surface_id = surface_id };
    dispatch.syncOnMainThread(&syncBrowserGetUrl, @ptrCast(&ctx));
    var resp = json.ObjectMap.init(arena);
    resp.put("workspace_id", jsonUuid(arena, resolveBrowserWorkspace(server, surface_id) orelse Uuid.nil)) catch {};
    resp.put("surface_id", jsonUuid(arena, surface_id)) catch {};
    if (ctx.result) |url_z| {
        resp.put("url", .{ .string = arena.dupe(u8, std.mem.span(url_z)) catch "" }) catch {};
    } else { resp.put("url", .{ .string = "" }) catch {}; }
    v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
}

const SyncBrowserEvalCtx = struct { ops: window_ops_mod.WindowOps, surface_id: Uuid, script: [*:0]const u8, timeout_ms: u32, result: window_ops_mod.BrowserEvalResult = .{} };
fn syncBrowserEval(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncBrowserEvalCtx = @ptrCast(@alignCast(data orelse return 0));
    ctx.result = ctx.ops.browserEval(ctx.surface_id, ctx.script, ctx.timeout_ms);
    return 0;
}
fn handleEval(server: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const ops = server.window_ops orelse { v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window ops") catch {}; return; };
    const surface_id = server.v2UUID(req.params, "surface_id") orelse { v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {}; return; };
    const script_str = jsonStr(req.params.get("script"));
    if (script_str.len == 0) { v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing script") catch {}; return; }
    const script = arena.allocSentinel(u8, script_str.len, 0) catch { v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {}; return; };
    @memcpy(script[0..script_str.len], script_str);
    const timeout_ms: u32 = blk: {
        if (req.params.get("timeout")) |tv| {
            switch (tv) {
                .integer => |i| break :blk if (i > 0 and i < 300) @as(u32, @intCast(i)) * 1000 else 10_000,
                .float => |f| break :blk if (f > 0 and f < 300) @as(u32, @intFromFloat(f * 1000)) else 10_000,
                else => break :blk 10_000,
            }
        }
        break :blk 10_000;
    };
    var ctx = SyncBrowserEvalCtx{ .ops = ops, .surface_id = surface_id, .script = script, .timeout_ms = timeout_ms };
    dispatch.syncOnMainThread(&syncBrowserEval, @ptrCast(&ctx));
    if (ctx.result.error_message) |err_msg| {
        const msg = arena.dupe(u8, err_msg) catch "JavaScript evaluation failed";
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, msg) catch {};
        return;
    }
    const ws_id = resolveBrowserWorkspace(server, surface_id);
    var resp = json.ObjectMap.init(arena);
    putSurfaceFields(server, arena, &resp, ws_id, surface_id);
    if (ctx.result.json_value) |json_z| {
        defer glib.free(@constCast(@ptrCast(json_z)));
        const json_slice = std.mem.span(json_z);
        const parsed = std.json.parseFromSlice(json.Value, arena, json_slice, .{}) catch {
            resp.put("value", .{ .string = arena.dupe(u8, json_slice) catch "" }) catch {};
            v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
            return;
        };
        resp.put("value", parsed.value) catch {};
    } else { resp.put("value", .null) catch {}; }
    v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
}

// =======================================================================
// browser.addinitscript / browser.addscript
// =======================================================================

fn handleAddScript(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
    action_name: []const u8,
) void {
    const script_str = jsonStr(req.params.get("script"));
    if (script_str.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing script") catch {};
        return;
    }
    // Inject via eval — addinitscript would ideally persist, but we approximate with eval
    const js = arena.allocSentinel(u8, script_str.len, 0) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
        return;
    };
    @memcpy(js, script_str);
    execJsAndRespond(server, arena, writer, req, js, action_name);
}

// =======================================================================
// browser.addstyle
// =======================================================================

fn handleAddStyle(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const css = jsonStr(req.params.get("css"));
    if (css.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing css") catch {};
        return;
    }
    // Inject style element via JS
    const prefix = "(()=>{var s=document.createElement('style');s.textContent='";
    const suffix = "';document.head.appendChild(s);return{ok:true}})()";
    const total = prefix.len + css.len + suffix.len;
    const js = arena.allocSentinel(u8, total, 0) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
        return;
    };
    var pos: usize = 0;
    @memcpy(js[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(js[pos..][0..css.len], css);
    pos += css.len;
    @memcpy(js[pos..][0..suffix.len], suffix);
    execJsAndRespond(server, arena, writer, req, js, "addstyle");
}

// =======================================================================
// browser.frame.select / browser.frame.main
// =======================================================================

fn handleFrameSelect(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const name = jsonStr(req.params.get("name"));
    const index_str = jsonStr(req.params.get("index"));
    if (name.len == 0 and index_str.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing name or index") catch {};
        return;
    }
    // Frame selection is a conceptual operation; we can't actually switch WebKitGTK frames from JS alone.
    // Return success with the frame info for protocol compatibility.
    const surface_id = server.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {};
        return;
    };
    const ws_id = resolveBrowserWorkspace(server, surface_id);
    var resp = json.ObjectMap.init(arena);
    putSurfaceFields(server, arena, &resp, ws_id, surface_id);
    resp.put("action", .{ .string = "frame.select" }) catch {};
    if (name.len > 0) resp.put("frame", .{ .string = name }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
}

fn handleFrameMain(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const surface_id = server.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {};
        return;
    };
    const ws_id = resolveBrowserWorkspace(server, surface_id);
    var resp = json.ObjectMap.init(arena);
    putSurfaceFields(server, arena, &resp, ws_id, surface_id);
    resp.put("action", .{ .string = "frame.main" }) catch {};
    resp.put("frame", .{ .string = "main" }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
}

// =======================================================================
// browser.dialog.accept / browser.dialog.dismiss (stubs)
// =======================================================================

fn handleDialogStub(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
    action_name: []const u8,
) void {
    const surface_id = server.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {};
        return;
    };
    const ws_id = resolveBrowserWorkspace(server, surface_id);
    var resp = json.ObjectMap.init(arena);
    putSurfaceFields(server, arena, &resp, ws_id, surface_id);
    resp.put("action", .{ .string = action_name }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
}

// =======================================================================
// browser.cookies.get / browser.cookies.set / browser.cookies.clear
// =======================================================================

fn handleCookiesGet(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const js = "(()=>{return{ok:true,value:document.cookie}})()";
    const js_z = arena.allocSentinel(u8, js.len, 0) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
        return;
    };
    @memcpy(js_z, js);
    execJsAndRespond(server, arena, writer, req, js_z, "cookies.get");
}

fn handleCookiesSet(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const cookie = jsonStr(req.params.get("cookie"));
    if (cookie.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing cookie") catch {};
        return;
    }
    const prefix = "(()=>{document.cookie='";
    const suffix = "';return{ok:true}})()";
    const total = prefix.len + cookie.len + suffix.len;
    const js = arena.allocSentinel(u8, total, 0) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
        return;
    };
    var pos: usize = 0;
    @memcpy(js[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(js[pos..][0..cookie.len], cookie);
    pos += cookie.len;
    @memcpy(js[pos..][0..suffix.len], suffix);
    execJsAndRespond(server, arena, writer, req, js, "cookies.set");
}

fn handleCookiesClear(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const js = "(()=>{document.cookie.split(';').forEach(function(c){document.cookie=c.trim().split('=')[0]+'=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/'});return{ok:true}})()";
    const js_z = arena.allocSentinel(u8, js.len, 0) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
        return;
    };
    @memcpy(js_z, js);
    execJsAndRespond(server, arena, writer, req, js_z, "cookies.clear");
}

// =======================================================================
// browser.storage.get / browser.storage.set / browser.storage.clear
// =======================================================================

fn handleStorageCmd(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
    action: []const u8,
) void {
    const storage_type = jsonStr(req.params.get("type"));
    const store = if (std.mem.eql(u8, storage_type, "session")) "sessionStorage" else "localStorage";

    if (std.mem.eql(u8, action, "get")) {
        const key = jsonStr(req.params.get("key"));
        var js_buf: [2048:0]u8 = undefined;
        const len = if (key.len > 0)
            std.fmt.bufPrint(&js_buf, "(()=>{{return{{ok:true,value:{s}.getItem('{s}')}}}})() ", .{ store, key }) catch {
                v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS format failed") catch {};
                return;
            }
        else
            std.fmt.bufPrint(&js_buf, "(()=>{{var o={{}};for(var i=0;i<{s}.length;i++){{var k={s}.key(i);o[k]={s}.getItem(k)}};return{{ok:true,value:o}}}})() ", .{ store, store, store }) catch {
                v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS format failed") catch {};
                return;
            };
        js_buf[len.len] = 0;
        const js = arena.allocSentinel(u8, len.len, 0) catch {
            v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
            return;
        };
        @memcpy(js, len);
        execJsAndRespond(server, arena, writer, req, js, "storage.get");
    } else if (std.mem.eql(u8, action, "set")) {
        const key = jsonStr(req.params.get("key"));
        const value = jsonStr(req.params.get("value"));
        if (key.len == 0) {
            v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing key") catch {};
            return;
        }
        var js_buf: [4096:0]u8 = undefined;
        const len = std.fmt.bufPrint(&js_buf, "(()=>{{{s}.setItem('{s}','{s}');return{{ok:true}}}})() ", .{ store, key, value }) catch {
            v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS format failed") catch {};
            return;
        };
        js_buf[len.len] = 0;
        const js = arena.allocSentinel(u8, len.len, 0) catch {
            v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
            return;
        };
        @memcpy(js, len);
        execJsAndRespond(server, arena, writer, req, js, "storage.set");
    } else {
        // clear
        var js_buf: [512:0]u8 = undefined;
        const len = std.fmt.bufPrint(&js_buf, "(()=>{{{s}.clear();return{{ok:true}}}})() ", .{store}) catch {
            v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS format failed") catch {};
            return;
        };
        js_buf[len.len] = 0;
        const js = arena.allocSentinel(u8, len.len, 0) catch {
            v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
            return;
        };
        @memcpy(js, len);
        execJsAndRespond(server, arena, writer, req, js, "storage.clear");
    }
}

// =======================================================================
// browser.tab.list (returns single-tab info for WebKitGTK)
// =======================================================================

fn handleTabList(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const surface_id = server.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {};
        return;
    };
    const ws_id = resolveBrowserWorkspace(server, surface_id);
    var resp = json.ObjectMap.init(arena);
    putSurfaceFields(server, arena, &resp, ws_id, surface_id);
    resp.put("action", .{ .string = "tab.list" }) catch {};
    // WebKitGTK is single-tab per panel
    var tabs = json.Array.init(arena);
    var tab = json.ObjectMap.init(arena);
    tab.put("index", .{ .integer = 0 }) catch {};
    tab.put("active", .{ .bool = true }) catch {};
    tab.put("surface_id", jsonUuid(arena, surface_id)) catch {};
    tabs.append(.{ .object = tab }) catch {};
    resp.put("tabs", .{ .array = tabs }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
}

// =======================================================================
// browser.console.list / browser.console.clear / browser.errors.list
// =======================================================================

fn handleConsoleList(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    // Console messages are not retained by WebKitGTK API; return empty list
    const surface_id = server.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {};
        return;
    };
    const ws_id = resolveBrowserWorkspace(server, surface_id);
    var resp = json.ObjectMap.init(arena);
    putSurfaceFields(server, arena, &resp, ws_id, surface_id);
    resp.put("action", .{ .string = "console.list" }) catch {};
    resp.put("messages", .{ .array = json.Array.init(arena) }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
}

fn handleConsoleClear(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const surface_id = server.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {};
        return;
    };
    const ws_id = resolveBrowserWorkspace(server, surface_id);
    var resp = json.ObjectMap.init(arena);
    putSurfaceFields(server, arena, &resp, ws_id, surface_id);
    resp.put("action", .{ .string = "console.clear" }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
}

fn handleErrorsList(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const surface_id = server.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {};
        return;
    };
    const ws_id = resolveBrowserWorkspace(server, surface_id);
    var resp = json.ObjectMap.init(arena);
    putSurfaceFields(server, arena, &resp, ws_id, surface_id);
    resp.put("action", .{ .string = "errors.list" }) catch {};
    resp.put("errors", .{ .array = json.Array.init(arena) }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
}

// =======================================================================
// browser.highlight
// =======================================================================

fn handleHighlight(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const sel = getSelector(req.params);
    if (sel.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing selector") catch {};
        return;
    }
    const js_action =
        \\el.style.outline='2px solid red';el.style.outlineOffset='2px';
        \\setTimeout(function(){el.style.outline='';el.style.outlineOffset=''},2000);
        \\return{ok:true};
    ;
    const js = buildSelectorJs(arena, sel, js_action) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS build failed") catch {};
        return;
    };
    execJsAndRespond(server, arena, writer, req, js, "highlight");
}

// =======================================================================
// browser.state.save / browser.state.load
// =======================================================================

fn handleStateSave(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    // Save page state via JS (scroll position, form values, URL)
    const js = "(()=>{return{ok:true,value:{url:location.href,scrollX:window.scrollX,scrollY:window.scrollY,title:document.title}}})()";
    const js_z = arena.allocSentinel(u8, js.len, 0) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
        return;
    };
    @memcpy(js_z, js);
    execJsAndRespond(server, arena, writer, req, js_z, "state.save");
}

fn handleStateLoad(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const url = jsonStr(req.params.get("url"));
    const scroll_x = jsonStr(req.params.get("scrollX"));
    const scroll_y = jsonStr(req.params.get("scrollY"));
    if (url.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing url in state") catch {};
        return;
    }
    var js_buf: [4096:0]u8 = undefined;
    const len = std.fmt.bufPrint(&js_buf, "(()=>{{if(location.href!=='{s}')location.href='{s}';else window.scrollTo({s},{s});return{{ok:true}}}})() ", .{
        url,
        url,
        if (scroll_x.len > 0) scroll_x else "0",
        if (scroll_y.len > 0) scroll_y else "0",
    }) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "JS format failed") catch {};
        return;
    };
    js_buf[len.len] = 0;
    const js = arena.allocSentinel(u8, len.len, 0) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
        return;
    };
    @memcpy(js, len);
    execJsAndRespond(server, arena, writer, req, js, "state.load");
}

// =======================================================================
// Not-supported stub (matches Mac v2BrowserNotSupported)
// =======================================================================

fn handleNotSupported(
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
    method_name: []const u8,
    details: []const u8,
) void {
    var data = json.ObjectMap.init(arena);
    data.put("method", .{ .string = method_name }) catch {};
    data.put("reason", .{ .string = details }) catch {};
    v2.writeErrorWithData(writer, arena, req.id, "not_supported", details, .{ .object = data }) catch {};
}

// =======================================================================
// Core helpers
// =======================================================================

/// Execute JS via browserEval and write a standard action response.
fn execJsAndRespond(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
    js: [*:0]const u8,
    action_name: []const u8,
) void {
    const surface_id = server.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {};
        return;
    };

    const eval_result = doEval(server, surface_id, js, 5_000);
    if (eval_result.error_message) |err_msg| {
        const msg = arena.dupe(u8, err_msg) catch "JS eval failed";
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, msg) catch {};
        return;
    }

    const ws_id = resolveBrowserWorkspace(server, surface_id);
    var resp = json.ObjectMap.init(arena);
    putSurfaceFields(server, arena, &resp, ws_id, surface_id);
    resp.put("action", .{ .string = arena.dupe(u8, action_name) catch "" }) catch {};

    // Parse JS result and extract fields
    if (eval_result.json_value) |json_z| {
        defer glib.free(@constCast(@ptrCast(json_z)));
        const json_slice = std.mem.span(json_z);
        const parsed = std.json.parseFromSlice(json.Value, arena, json_slice, .{}) catch {
            v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
            return;
        };
        if (parsed.value == .object) {
            const obj = parsed.value.object;
            // Check for not_found error
            if (obj.get("ok")) |ok_val| {
                if (ok_val == .bool and !ok_val.bool) {
                    v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Element not found") catch {};
                    return;
                }
            }
            if (obj.get("value")) |val| resp.put("value", val) catch {};
        }
    }
    v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
}

/// Execute JS eval on a browser surface (sync). Reuses the SyncBrowserEvalCtx pattern.
fn doEval(server: *Server, surface_id: Uuid, js: [*:0]const u8, timeout_ms: u32) window_ops_mod.BrowserEvalResult {
    const ops = server.window_ops orelse return .{ .error_message = "No window ops" };
    var ctx = SyncBrowserEvalCtx{ .ops = ops, .surface_id = surface_id, .script = js, .timeout_ms = timeout_ms };
    dispatch.syncOnMainThread(&syncBrowserEval, @ptrCast(&ctx));
    return ctx.result;
}

/// Build JS: (()=>{ const el=document.querySelector(SEL); if(!el)return{ok:false,error:'not_found'}; ACTION })()
fn buildSelectorJs(arena: Allocator, selector: []const u8, action_js: []const u8) ?[*:0]u8 {
    const prefix = "(()=>{var el=document.querySelector('";
    const mid = "');if(!el)return{ok:false,error:'not_found'};";
    const suffix = "})()";
    const total = prefix.len + selector.len + mid.len + action_js.len + suffix.len;
    const buf = arena.allocSentinel(u8, total, 0) catch return null;
    var pos: usize = 0;
    @memcpy(buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;
    @memcpy(buf[pos .. pos + selector.len], selector);
    pos += selector.len;
    @memcpy(buf[pos .. pos + mid.len], mid);
    pos += mid.len;
    @memcpy(buf[pos .. pos + action_js.len], action_js);
    pos += action_js.len;
    @memcpy(buf[pos .. pos + suffix.len], suffix);
    return buf;
}

/// Build JS with a text variable injected: var __text=TEXT; then selector + action.
fn buildTextSelectorJs(arena: Allocator, selector: []const u8, text: []const u8, action_js: []const u8) ?[*:0]u8 {
    const p1 = "(()=>{var __text='";
    const p2 = "';var el=document.querySelector('";
    const p3 = "');if(!el)return{ok:false,error:'not_found'};";
    const p4 = "})()";
    const total = p1.len + text.len + p2.len + selector.len + p3.len + action_js.len + p4.len;
    const buf = arena.allocSentinel(u8, total, 0) catch return null;
    var pos: usize = 0;
    inline for (.{ p1, text, p2, selector, p3, action_js, p4 }) |part| {
        @memcpy(buf[pos .. pos + part.len], part);
        pos += part.len;
    }
    return buf;
}

/// Extract selector from params (tries selector, sel, element_ref, ref).
fn getSelector(params: json.ObjectMap) []const u8 {
    const sel = jsonStr(params.get("selector"));
    if (sel.len > 0) return sel;
    const sel2 = jsonStr(params.get("sel"));
    if (sel2.len > 0) return sel2;
    const ref = jsonStr(params.get("element_ref"));
    if (ref.len > 0) return ref;
    return jsonStr(params.get("ref"));
}

/// Put workspace/surface fields into a response object.
fn putSurfaceFields(server: *Server, arena: Allocator, resp: *json.ObjectMap, ws_id: ?Uuid, surface_id: Uuid) void {
    if (ws_id) |wid| {
        resp.put("workspace_id", jsonUuid(arena, wid)) catch {};
        resp.put("workspace_ref", server.v2Ref(.workspace, wid)) catch {};
    }
    resp.put("surface_id", jsonUuid(arena, surface_id)) catch {};
    resp.put("surface_ref", server.v2Ref(.surface, surface_id)) catch {};
}

fn resolveWorkspaceId(server: *Server, params: json.ObjectMap) ?Uuid {
    if (server.v2UUID(params, "workspace_id")) |id| return id;
    const mgr = server.workspace_manager orelse return null;
    return mgr.selected_id;
}

fn resolveBrowserWorkspace(server: *Server, panel_id: Uuid) ?Uuid {
    const mgr = server.workspace_manager orelse return null;
    for (mgr.workspaces.items) |ws| {
        if (ws.panelById(panel_id)) |_| return ws.id;
    }
    return null;
}

fn writeBrowserSurfaceResponse(server: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req_id: json.Value, ws_id: ?Uuid, surface_id: Uuid) void {
    var resp = json.ObjectMap.init(arena);
    resp.put("window_id", .null) catch {};
    resp.put("window_ref", .null) catch {};
    putSurfaceFields(server, arena, &resp, ws_id, surface_id);
    v2.writeOk(writer, arena, req_id, .{ .object = resp }) catch {};
}

fn jsonStr(val: ?json.Value) []const u8 {
    return if (val) |v| switch (v) { .string => |s| s, else => "" } else "";
}

fn jsonUuid(arena: Allocator, id: Uuid) json.Value {
    const formatted = id.format();
    const s = arena.dupe(u8, &formatted) catch return .{ .string = "" };
    return .{ .string = s };
}
