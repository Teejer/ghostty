//! The per-tab AI panel docked to the right side of each tab.
//!
//! Each panel belongs to exactly one tab and its lifetime is tied to
//! it. The panel is a client of the ghostty-ai daemon over a unix
//! socket (see the ghostty-ai repository for the protocol). All socket
//! I/O happens on the GTK main thread: writes are small non-blocking
//! local writes and reads are drained by a 100ms GSource timer, which
//! keeps us out of GIO async callback lifetime puzzles entirely.

const std = @import("std");
const c = std.c;

// The handful of C socket calls we need, declared by hand because Zig
// 0.17 removed @cImport and std.Io.net is heavier than a local socket
// connection deserves.
extern fn socket(domain: c_int, ty: c_int, protocol: c_int) callconv(.c) c_int;
extern fn connect(fd: c_int, addr: *const anyopaque, len: u32) callconv(.c) c_int;
extern fn read(fd: c_int, buf: [*]align(1) u8, count: usize) callconv(.c) isize;
extern fn write(fd: c_int, buf: [*]align(1) const u8, count: usize) callconv(.c) isize;
extern fn close(fd: c_int) callconv(.c) c_int;
extern fn fcntl(fd: c_int, cmd: c_int, ...) callconv(.c) c_int;
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gdk = @import("gdk");

const Common = @import("../class.zig").Common;

const global = @import("../../../global.zig");
const Application = @import("application.zig").Application;
const Tab = @import("tab.zig").Tab;

const log = std.log.scoped(.gtk_ai_panel);

pub const AiPanel = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyAiPanel",
        .instanceInit = &init,
        .classInit = &Class.init,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    /// One provider as described by the daemon.
    const DaemonProvider = struct {
        name: []const u8 = "",
        label: []const u8 = "",
        model: []const u8 = "",
    };

    /// A message received from the daemon.
    const DaemonMsg = struct {
        type: []const u8 = "",
        text: ?[]const u8 = null,
        message: ?[]const u8 = null,
        state: ?[]const u8 = null,
        provider: ?[]const u8 = null,
        label: ?[]const u8 = null,
        model: ?[]const u8 = null,
        providers: []const DaemonProvider = &.{},
        id: ?[]const u8 = null,
        command: ?[]const u8 = null,
        auto: ?bool = null,
    };

    const Private = struct {
        /// One collapsible "thinking" block in the transcript. The
        /// button is a child anchor inside the TextView; the body text
        /// spans the two marks and is hidden via the shared invisible
        /// tag when collapsed.
        const ThinkingBlock = struct {
            button: *gtk.Button,
            start: *gtk.TextMark,
            end: ?*gtk.TextMark = null,
            hidden: bool = true,
        };

        /// Chat transcript shown to the user.
        transcript: *gtk.TextView = undefined,

        /// Scroller around the transcript, for auto-scroll.
        scroller: *gtk.ScrolledWindow = undefined,

        /// The tab this panel belongs to. A panel can only ever read or
        /// affect its own tab and the tab always outlives the panel.
        tab: ?*Tab = null,

        /// Stable identity for this tab's session in the daemon.
        tab_id: ?[*:0]u8 = null,

        /// Daemon connection. fd is -1 when disconnected.
        fd: c_int = -1,

        /// Buffered inbound bytes not yet terminated by a newline.
        read_buf: std.ArrayList(u8) = .empty,

        /// The poll timer GSource while connected.
        poll_source: ?c_uint = null,

        /// True while we are mid-way writing an assistant turn so we
        /// only prefix the "ai: " label once per turn.
        ai_turn_open: bool = false,

        /// Text tags: user messages get a blue background; thinking
        /// bodies are italic/dim and additionally invisible when
        /// collapsed.
        tag_user: ?*gtk.TextTag = null,
        tag_think: ?*gtk.TextTag = null,
        tag_hidden: ?*gtk.TextTag = null,

        /// Collapsible thinking blocks; open_think indexes the block
        /// currently receiving reasoning deltas, if any.
        thinking_blocks: std.ArrayList(ThinkingBlock) = .empty,
        open_think: ?usize = null,

        /// AI-proposed command awaiting this tab's decision (Run/Deny
        /// buttons) or running with output capture (exec_active).
        exec_id: ?[]u8 = null,
        exec_cmd: ?[]u8 = null,
        exec_run_btn: ?*gtk.Button = null,
        exec_deny_btn: ?*gtk.Button = null,
        exec_active: bool = false,
        exec_interactive: bool = false,
        exec_before: ?[]u8 = null,
        exec_last: ?[]u8 = null,
        exec_elapsed_ms: u32 = 0,
        exec_stable_ms: u32 = 0,
        exec_tick: u32 = 0,

        /// One-shot scroll timer (see scrollSoon).
        scroll_soon: ?c_uint = null,

        /// Multiline prompt input; the scrolled window caps its growth
        /// at about five lines, and the placeholder label covers the
        /// empty state (TextView has no placeholder of its own).
        input_view: ?*gtk.TextView = null,
        input_scroll: ?*gtk.ScrolledWindow = null,
        input_placeholder: ?*gtk.Label = null,
        input_line_h: c_int = 0,

        /// Per-tab model picker. The provider list comes from the
        /// daemon and applies to this tab's session only.
        provider_row: ?*gtk.Box = null,
        provider_drop: ?*gtk.DropDown = null,
        provider_names: [][]const u8 = &.{},
        providers_updating: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    /// Bind this panel to the tab that owns it.
    pub fn setTab(self: *Self, tab: *Tab) void {
        self.private().tab = tab;
    }

    /// Append text to the chat transcript with an optional tag.
    fn append(self: *Self, text: []const u8, tag: ?*gtk.TextTag) void {
        const priv = self.private();
        const buffer = priv.transcript.getBuffer();

        const z = glib.ext.dupeZ(u8, text);
        defer glib.free(z.ptr);

        var start_iter: gtk.TextIter = undefined;
        buffer.getEndIter(&start_iter);
        const start_off = start_iter.getOffset();

        buffer.insert(&start_iter, z, -1);

        if (tag) |t| {
            var s: gtk.TextIter = undefined;
            var e: gtk.TextIter = undefined;
            buffer.getIterAtOffset(&s, start_off);
            buffer.getEndIter(&e);
            buffer.applyTag(t, &s, &e);
        }

        self.scrollToBottomIfFollowing();
    }

    /// Auto-scroll, but only when the user was already looking at the
    /// bottom, so scrolling up through old chat is not hijacked by
    /// streaming output.
    fn scrollToBottomIfFollowing(self: *Self) void {
        const priv = self.private();
        const adj = priv.scroller.getVadjustment();
        const upper = adj.getUpper();
        const page = adj.getPageSize();
        const value = adj.getValue();
        if (upper - page - value < 64) adj.setValue(upper);
    }

    /// Pad the text inserted since start_off with spaces (tagged like
    /// the text) so its background spans the full transcript width.
    /// The transcript is monospace, so two adjacent cells give us the
    /// glyph advance and thus the visible column count. Wrapped lines
    /// are handled by filling to a multiple of the column count.
    /// Padding is computed at write time: after a window resize, older
    /// bars keep their old width.
    fn padTaggedLine(self: *Self, start_off: usize) void {
        const priv = self.private();
        const buffer = priv.transcript.getBuffer();
        var e: gtk.TextIter = undefined;
        buffer.getEndIter(&e);
        const end_off: usize = @intCast(e.getOffset());
        const len = end_off -| start_off;
        const cols = self.transcriptCols();

        var pad = cols - (len % cols);
        if (pad == cols) pad = 0; // exactly full
        if (pad == 0 or pad > 4096) return;

        const spaces = alloc().alloc(u8, pad) catch return;
        defer alloc().free(spaces);
        @memset(spaces, ' ');
        self.append(spaces, priv.tag_user);
    }

    /// Approximate number of monospace columns visible in the
    /// transcript view.
    fn transcriptCols(self: *Self) usize {
        const priv = self.private();
        const wpx = priv.transcript.as(gtk.Widget).getAllocatedWidth();
        if (wpx <= 0) return 80;
        const width: usize = @intCast(wpx);

        const buffer = priv.transcript.getBuffer();
        if (buffer.getCharCount() < 2) return 80;
        var ia: gtk.TextIter = undefined;
        var ib: gtk.TextIter = undefined;
        buffer.getIterAtOffset(&ia, 0);
        buffer.getIterAtOffset(&ib, 1);
        var r1: gdk.Rectangle = undefined;
        var r2: gdk.Rectangle = undefined;
        priv.transcript.getIterLocation(&ia, &r1);
        priv.transcript.getIterLocation(&ib, &r2);
        const advance: isize = r2.f_x - r1.f_x;
        if (advance <= 0) return 80;

        const usable: usize = if (width > 16) width - 16 else 2;
        return @max(usable / @as(usize, @intCast(advance)), 20);
    }

    /// Append text to the chat transcript.
    pub fn appendText(self: *Self, text: [:0]const u8) void {
        self.append(text, null);
    }

    /// Append arbitrary (non-terminated) text to the transcript.
    fn appendSlice(self: *Self, text: []const u8) void {
        self.append(text, null);
    }

    //---------------------------------------------------------------
    // Daemon connection
    //---------------------------------------------------------------

    fn alloc() std.mem.Allocator {
        return Application.default().allocator();
    }

    /// The daemon socket path from the environment or XDG_RUNTIME_DIR.
    /// Writes the XDG-derived path into buf; the returned slice is
    /// never owned.
    fn daemonSocketPath(buf: []u8) ?[]const u8 {
        if (global.environ().getPosix("GHOSTTY_AI_SOCKET")) |v| return v;
        const rt = global.environ().getPosix("XDG_RUNTIME_DIR") orelse return null;
        return std.fmt.bufPrint(
            buf,
            "{s}/ghostty-ai/daemon.sock",
            .{rt},
        ) catch null;
    }

    /// Connect to the daemon if not already connected and register this
    /// tab's session. Errors are reported into the transcript.
    pub fn ensureConnected(self: *Self) bool {
        const priv = self.private();
        if (priv.fd >= 0) return true;

        var path_buf: [4096]u8 = undefined;
        const path = daemonSocketPath(&path_buf) orelse {
            log.warn("no XDG_RUNTIME_DIR or GHOSTTY_AI_SOCKET in env", .{});
            self.appendText("[ghostty-ai] XDG_RUNTIME_DIR unset; cannot find daemon socket\n\n");
            return false;
        };
        log.debug("connecting to daemon path={s}", .{path});

        const fd = socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
        if (fd < 0) {
            self.appendText("[ghostty-ai] socket() failed\n\n");
            return false;
        }

        var addr: c.sockaddr.un = undefined;
        @memset(&addr.path, 0);
        addr.family = std.posix.AF.UNIX;
        if (path.len >= addr.path.len) {
            _ = close(fd);
            self.appendText("[ghostty-ai] socket path too long\n\n");
            return false;
        }
        @memcpy(addr.path[0..path.len], path);

        if (connect(
            fd,
            @ptrCast(&addr),
            @sizeOf(c.sockaddr.un),
        ) < 0) {
            const err = std.c._errno().*;
            _ = close(fd);
            log.warn("connect failed path={s} errno={d}", .{ path, err });
            self.appendSlice(
                "[ghostty-ai] daemon not running — start it with `ghostty-ai`\n\n",
            );
            return false;
        }

        // Non-blocking: everything here runs on the GTK main thread.
        const flags = fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
        const o_nonblock: c_uint = 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
        const flags_u: c_uint = @bitCast(@as(c_int, flags));
        const new_flags: c_uint = flags_u | o_nonblock;
        _ = fcntl(fd, std.posix.F.SETFL, @as(c_int, @bitCast(new_flags)));

        priv.fd = fd;

        // Start the read timer. 50ms keeps streaming visually smooth
        // without a thread or GIO async machinery.
        priv.poll_source = glib.timeoutAdd(50, pollDaemon, self);

        // Register our session.
        const tab_id = priv.tab_id orelse return false;
        self.sendJson(struct {
            type: []const u8 = "hello",
            tab_id: []const u8,
        }{ .tab_id = std.mem.span(tab_id) });

        self.appendText("[ghostty-ai] connected, waiting for daemon…\n");
        return true;
    }

    fn sendJson(self: *Self, value: anytype) void {
        const priv = self.private();
        if (priv.fd < 0) return;

        var buf: std.Io.Writer.Allocating = .init(alloc());
        defer buf.deinit();
        buf.writer.print(
            "{f}\n",
            .{std.json.fmt(value, .{ .emit_null_optional_fields = false })},
        ) catch return;

        var left: []const u8 = buf.written();
        while (left.len > 0) {
            const n = write(priv.fd, @ptrCast(left.ptr), left.len);
            if (n < 0) {
                const e = std.c._errno().*;
                if (e == @intFromEnum(std.c.E.INTR)) continue;
                log.warn("daemon write failed fd={d} errno={d}", .{ priv.fd, e });
                return; // EAGAIN or error: drop (MVP)
            }
            left = left[@intCast(n)..];
        }
    }

    /// GSource timer draining the daemon socket. Returns 1 to keep
    /// running or 0 when disconnected (and cleans up).
    fn pollDaemon(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        if (priv.fd < 0) return 0;

        var chunk: [16384]u8 = undefined;
        while (true) {
            const n = read(priv.fd, @ptrCast(&chunk), chunk.len);
            if (n > 0) {
                priv.read_buf.appendSlice(alloc(), chunk[0..@intCast(n)]) catch {
                    disconnect(self, "[ghostty-ai] out of memory reading daemon\n\n");
                    return 0;
                };
                drainLines(self);
            } else if (n == 0) {
                disconnect(self, "[ghostty-ai] daemon disconnected\n\n");
                return 0;
            } else {
                const e = std.c._errno().*;
                const again = @intFromEnum(std.c.E.AGAIN);
                const intr = @intFromEnum(std.c.E.INTR);
                if (e == again or e == intr) break;
                disconnect(self, "[ghostty-ai] read error\n\n");
                return 0;
            }
        }
        if (priv.exec_active) self.execPollTick();
        return 1;
    }

    fn drainLines(self: *Self) void {
        const priv = self.private();
        while (std.mem.indexOfScalar(u8, priv.read_buf.items, '\n')) |idx| {
            const line = priv.read_buf.items[0..idx];
            self.dispatchLine(line);
            // Drop the processed line by shifting the remainder down.
            const rest = priv.read_buf.items[idx + 1 ..];
            std.mem.copyForwards(u8, priv.read_buf.items, rest);
            priv.read_buf.shrinkRetainingCapacity(rest.len);
        }
    }

    fn dispatchLine(self: *Self, line: []const u8) void {
        const parsed = std.json.parseFromSlice(
            DaemonMsg,
            alloc(),
            line,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            log.warn("unparseable daemon line err={} line={s}", .{ err, line });
            return;
        };
        defer parsed.deinit();
        const msg = parsed.value;

        if (std.mem.eql(u8, msg.type, "ready")) {
            const p = msg.provider orelse "?";
            const shown = msg.label orelse p;
            const s = std.fmt.allocPrintSentinel(
                alloc(),
                "\n[ghostty-ai] session ready: {s}\n\n",
                .{shown},
                0,
            ) catch return;
            defer alloc().free(s);
            self.appendText(s);
            if (msg.message) |warning| {
                self.appendSlice("\n[ghostty-ai] ");
                self.appendSlice(warning);
                self.appendText("\n\n");
            }
            if (msg.providers.len > 0) self.rebuildProviders(msg.providers, p);
        } else if (std.mem.eql(u8, msg.type, "thinking")) {
            const priv = self.private();
            if (priv.open_think == null) self.beginThinkingBlock();
            self.appendThinkingText(priv.open_think.?, msg.text orelse "");
        } else if (std.mem.eql(u8, msg.type, "delta")) {
            const priv = self.private();
            // Reasoning is over; answer text begins.
            self.closeThinkingBlock();
            if (!priv.ai_turn_open) {
                priv.ai_turn_open = true;
                self.appendText("\nai: ");
            }
            self.appendSlice(msg.text orelse "");
        } else if (std.mem.eql(u8, msg.type, "done")) {
            self.closeThinkingBlock();
            const priv = self.private();
            if (priv.ai_turn_open) {
                priv.ai_turn_open = false;
                self.appendText("\n");
            }
        } else if (std.mem.eql(u8, msg.type, "error")) {
            self.closeThinkingBlock();
            const priv = self.private();
            priv.ai_turn_open = false;
            self.appendText("\n[ghostty-ai error] ");
            self.appendSlice(msg.message orelse "unknown error");
            self.appendText("\n\n");
        } else if (std.mem.eql(u8, msg.type, "exec")) {
            const cmd = msg.command orelse "";
            const id = msg.id orelse "";
            log.debug("exec proposal id={s} auto={?} cmd={s}", .{ id, msg.auto, cmd });
            if (msg.auto orelse false) {
                const auto_note = std.fmt.allocPrintSentinel(
                    alloc(),
                    "\n[exec] auto-running: {s}\n",
                    .{cmd},
                    0,
                ) catch return;
                defer alloc().free(auto_note);
                self.appendText(auto_note);
                self.startExec(id, cmd);
            } else {
                self.closeThinkingBlock();
                self.private().ai_turn_open = false;
                self.appendText("\n[exec] The AI wants to run this in your tab:\n");
                self.appendSlice(cmd);
                self.appendText("\n");
                self.appendExecButtons(id, cmd);
            }
        } else if (std.mem.eql(u8, msg.type, "exec_cancel")) {
            self.clearExecProposal();
        } else if (std.mem.eql(u8, msg.type, "status")) {
            // No UI for turn states yet.
        }
    }

    /// Rebuild the per-tab model picker from the daemon's provider list,
    /// selecting the session's current provider. Dropdown labels are the
    /// config-provided display names; set_provider still uses the key.
    fn rebuildProviders(self: *Self, infos: []const DaemonProvider, current: []const u8) void {
        const priv = self.private();
        const a = alloc();

        for (priv.provider_names) |n| a.free(n);
        priv.provider_names = a.alloc([]const u8, infos.len) catch return;

        // GTK wants a null-terminated array of C strings; it dups them
        // during construction, so our copies must outlive that call and
        // only then be freed. (A `defer` inside the loop would free at
        // each iteration's end, before GTK reads them.)
        var strs: std.ArrayList(?[*:0]const u8) = .empty;
        defer strs.deinit(a);
        for (infos, 0..) |info, i| {
            priv.provider_names[i] = a.dupe(u8, info.name) catch return;
            const display = if (info.label.len > 0) info.label else info.name;
            const z = glib.ext.dupeZ(u8, display);
            strs.append(a, z.ptr) catch {
                glib.free(@constCast(@ptrCast(z.ptr)));
                return;
            };
        }
        strs.append(a, null) catch {
            for (strs.items) |maybe| if (maybe) |pp| glib.free(@constCast(@ptrCast(pp)));
            return;
        };
        defer for (strs.items) |maybe| if (maybe) |pp| glib.free(@constCast(@ptrCast(pp)));

        // Replace the old dropdown, if any.
        if (priv.provider_drop) |old| {
            if (priv.provider_row) |row| row.remove(old.as(gtk.Widget));
            priv.provider_drop = null;
        }

        const drop = gtk.DropDown.newFromStrings(@ptrCast(strs.items.ptr));
        var sel: c_uint = 0;
        for (priv.provider_names, 0..) |n, i| {
            if (std.mem.eql(u8, n, current)) sel = @intCast(i);
        }
        drop.setSelected(sel);

        // Connect after setting the initial selection so we do not
        // immediately send a redundant set_provider.
        _ = gobject.Object.signals.notify.connect(
            drop.as(gobject.Object),
            *Self,
            onProviderNotify,
            self,
            .{ .detail = "selected" },
        );
        priv.provider_drop = drop;

        if (priv.provider_row) |row| {
            row.append(drop.as(gtk.Widget));
            row.as(gtk.Widget).setVisible(1);
        }
    }

    fn onProviderNotify(
        _: *gobject.Object,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const drop = priv.provider_drop orelse return;
        const idx: usize = @intCast(drop.getSelected());
        if (idx >= priv.provider_names.len) return;
        const name = priv.provider_names[idx];
        log.debug("provider selected name={s}", .{name});
        self.sendJson(struct {
            type: []const u8 = "set_provider",
            provider: []const u8,
        }{ .provider = name });
    }

    //---------------------------------------------------------------
    // Collapsible thinking blocks
    //---------------------------------------------------------------

    /// Start a new collapsed thinking block: an inline toggle button
    /// (child anchor) followed by invisible reasoning text.
    fn beginThinkingBlock(self: *Self) void {
        const priv = self.private();
        const buffer = priv.transcript.getBuffer();

        var iter: gtk.TextIter = undefined;
        buffer.getEndIter(&iter);
        const anchor = buffer.createChildAnchor(&iter);

        const button = gtk.Button.newWithLabel("▸ thinking");
        button.as(gtk.Widget).addCssClass("flat");
        button.as(gtk.Widget).addCssClass("caption");
        _ = gtk.Button.signals.clicked.connect(
            button,
            *Self,
            onThinkingToggled,
            self,
            .{},
        );
        priv.transcript.addChildAtAnchor(button.as(gtk.Widget), anchor);

        self.append("\n", null);

        // The body range starts here; the mark tracks it as text
        // streams in.
        buffer.getEndIter(&iter);
        const start = buffer.createMark(null, &iter, 1);

        priv.thinking_blocks.append(alloc(), .{
            .button = button,
            .start = start,
        }) catch return;
        priv.open_think = priv.thinking_blocks.items.len - 1;
    }

    fn appendThinkingText(self: *Self, idx: usize, text: []const u8) void {
        const priv = self.private();
        if (idx >= priv.thinking_blocks.items.len) return;
        const blk = &priv.thinking_blocks.items[idx];

        const buffer = priv.transcript.getBuffer();
        var s: gtk.TextIter = undefined;
        buffer.getEndIter(&s);
        const off = s.getOffset();

        // Style tag (italic, dim) always; invisible on top while the
        // block is collapsed.
        self.append(text, priv.tag_think);
        if (blk.hidden) {
            var e: gtk.TextIter = undefined;
            buffer.getIterAtOffset(&s, off);
            buffer.getEndIter(&e);
            buffer.applyTag(priv.tag_hidden.?, &s, &e);
        }
    }

    /// Close the open thinking block, if any. The body stays collapsed
    /// under its button.
    fn closeThinkingBlock(self: *Self) void {
        const priv = self.private();
        const idx = priv.open_think orelse return;
        priv.open_think = null;
        const blk = &priv.thinking_blocks.items[idx];

        const buffer = priv.transcript.getBuffer();
        var e: gtk.TextIter = undefined;
        buffer.getEndIter(&e);
        blk.end = buffer.createMark(null, &e, 0);
    }

    fn onThinkingToggled(
        button: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        for (priv.thinking_blocks.items) |*blk| {
            if (blk.button != button) continue;

            const buffer = priv.transcript.getBuffer();
            var s: gtk.TextIter = undefined;
            var e: gtk.TextIter = undefined;
            buffer.getIterAtMark(&s, blk.start);
            if (blk.end) |m| buffer.getIterAtMark(&e, m) else buffer.getEndIter(&e);

            if (blk.hidden) {
                buffer.removeTag(priv.tag_hidden.?, &s, &e);
                blk.hidden = false;
                button.setLabel("▾ thinking");
            } else {
                buffer.applyTag(priv.tag_hidden.?, &s, &e);
                blk.hidden = true;
                button.setLabel("▸ thinking");
            }
            return;
        }
    }

    //---------------------------------------------------------------
    // Command approval and execution (the pty gate)
    //
    // Nothing reaches the terminal except through a click on these
    // buttons, into this tab's own surface. A compromised daemon can
    // propose; only the terminal can execute.
    //---------------------------------------------------------------

    /// Inline Run/Deny buttons under a command proposal.
    fn appendExecButtons(self: *Self, id: []const u8, cmd: []const u8) void {
        const priv = self.private();
        const a = alloc();
        self.clearExecProposal();

        const buffer = priv.transcript.getBuffer();
        var iter: gtk.TextIter = undefined;
        buffer.getEndIter(&iter);
        const anchor = buffer.createChildAnchor(&iter);
        self.append("\n", null);

        const box = gtk.Box.new(.horizontal, 6);
        const run = gtk.Button.newWithLabel("Run");
        run.as(gtk.Widget).addCssClass("suggested-action");
        const deny = gtk.Button.newWithLabel("Deny");
        deny.as(gtk.Widget).addCssClass("flat");
        _ = gtk.Button.signals.clicked.connect(
            run,
            *Self,
            onExecRunClicked,
            self,
            .{},
        );
        _ = gtk.Button.signals.clicked.connect(
            deny,
            *Self,
            onExecDenyClicked,
            self,
            .{},
        );
        box.append(run.as(gtk.Widget));
        box.append(deny.as(gtk.Widget));
        priv.transcript.addChildAtAnchor(box.as(gtk.Widget), anchor);

        priv.exec_id = a.dupe(u8, id) catch return;
        priv.exec_cmd = a.dupe(u8, cmd) catch return;
        priv.exec_run_btn = run;
        priv.exec_deny_btn = deny;
        self.scrollSoon();
    }

    /// Scroll to the bottom shortly. Child widgets added at anchors
    /// (the Run/Deny box) do not trigger a text-insert scroll, and the
    /// scroll adjustment does not know their height until the next
    /// layout pass, so a scroll now would land above them.
    fn scrollSoon(self: *Self) void {
        const priv = self.private();
        if (priv.scroll_soon) |id| _ = glib.Source.remove(id);
        priv.scroll_soon = glib.timeoutAdd(150, struct {
            fn call(ud: ?*anyopaque) callconv(.c) c_int {
                const self_: *Self = @ptrCast(@alignCast(ud));
                self_.private().scroll_soon = null;
                self_.scrollToBottomIfFollowing();
                return 0;
            }
        }.call, self);
    }

    fn onExecRunClicked(
        button: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const btn = priv.exec_run_btn orelse return;
        if (btn != button or priv.exec_active) return;
        const id = priv.exec_id orelse return;
        const cmd = priv.exec_cmd orelse return;
        button.as(gtk.Widget).setSensitive(0);
        if (priv.exec_deny_btn) |d| d.as(gtk.Widget).setSensitive(0);
        self.startExec(id, cmd);
    }

    fn onExecDenyClicked(
        button: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const btn = priv.exec_deny_btn orelse return;
        if (btn != button or priv.exec_active) return;
        const id = priv.exec_id orelse return;
        button.as(gtk.Widget).setSensitive(0);
        if (priv.exec_run_btn) |r| r.as(gtk.Widget).setSensitive(0);
        self.sendJson(struct {
            type: []const u8 = "exec_reply",
            id: []const u8,
            decision: []const u8 = "deny",
        }{ .id = id });
        self.appendText("[denied]\n");
        self.clearExecStrings();
    }

    /// Approved: write the command into our own tab's pty and start
    /// watching the screen for output.
    fn startExec(self: *Self, id: []const u8, cmd: []const u8) void {
        const priv = self.private();
        const a = alloc();

        // Escape for the core's config-string parser (the same one the
        // write: keybinding uses): double backslashes; the trailing
        // two-character \n decodes to Enter.
        var w: std.Io.Writer.Allocating = .init(a);
        defer w.deinit();
        for (cmd) |ch| {
            if (ch == '\\') {
                w.writer.writeAll("\\\\") catch return;
            } else w.writer.writeByte(ch) catch return;
        }
        w.writer.writeAll("\\n") catch return;

        const tab = priv.tab orelse {
            self.execReply(id, "failed", "");
            return;
        };
        log.debug("exec approved, injecting id={s}", .{id});
        if (!tab.injectText(w.written())) {
            self.appendText("[exec failed: no active surface]\n");
            self.execReply(id, "failed", "");
            return;
        }

        // Snapshot the screen so we can tell when output settles.
        if (priv.exec_before) |v| a.free(v);
        priv.exec_before = null;
        if (tab.dumpActiveSurfaceText(a)) |before| {
            priv.exec_before = @constCast(before);
        } else |_| {}

        priv.exec_active = true;
        priv.exec_interactive = isInteractiveCommand(cmd);
        priv.exec_elapsed_ms = 0;
        priv.exec_stable_ms = 0;
        priv.exec_tick = 0;
        if (priv.exec_last) |v| a.free(v);
        priv.exec_last = null;
    }

    /// Driven from the socket poll at ~300ms cadence. Done when two
    /// consecutive screen dumps match; timeouts keep long-running and
    /// interactive commands from parking the turn.
    fn execPollTick(self: *Self) void {
        const priv = self.private();
        const a = alloc();
        priv.exec_tick += 1;
        if (priv.exec_tick % 6 != 0) return;
        priv.exec_elapsed_ms += 300;

        const tab = priv.tab orelse {
            self.finishExec("failed", "");
            return;
        };
        const after = tab.dumpActiveSurfaceText(a) catch {
            self.finishExec("failed", "");
            return;
        };
        defer a.free(after);

        const stable = priv.exec_last != null and
            std.mem.eql(u8, priv.exec_last.?, after);
        if (stable) {
            priv.exec_stable_ms += 300;
        } else {
            priv.exec_stable_ms = 0;
            if (priv.exec_last) |v| a.free(v);
            priv.exec_last = a.dupe(u8, after) catch null;
        }

        const settle_ms: u32 = if (priv.exec_interactive) 700 else 900;
        const timeout_ms: u32 = if (priv.exec_interactive) 4_000 else 30_000;
        if (priv.exec_stable_ms >= settle_ms) {
            self.finishExec("done", after);
        } else if (priv.exec_elapsed_ms >= timeout_ms) {
            self.finishExec(
                if (priv.exec_interactive) "interactive" else "timeout",
                after,
            );
        }
    }

    fn finishExec(self: *Self, status: []const u8, output: []const u8) void {
        const priv = self.private();
        const id = priv.exec_id orelse return;
        // The screen tail is what just ran: command, output, prompt.
        const from = if (output.len > 8192) output.len - 8192 else 0;
        log.debug("exec finished status={s} output_bytes={}", .{ status, output.len });
        self.execReply(id, status, output[from..]);
        if (std.mem.eql(u8, status, "timeout")) {
            self.appendText("[exec] still running; sent the model the output so far\n");
        } else if (std.mem.eql(u8, status, "interactive")) {
            self.appendText("[exec] looks interactive; sent partial output, will not drive it\n");
        }
        priv.exec_active = false;
        self.clearExecStrings();
    }

    fn execReply(
        self: *Self,
        id: []const u8,
        status: []const u8,
        output: []const u8,
    ) void {
        self.sendJson(struct {
            type: []const u8 = "exec_reply",
            id: []const u8,
            decision: []const u8 = "approve",
            status: []const u8,
            output: []const u8,
        }{ .id = id, .status = status, .output = output });
    }

    fn clearExecStrings(self: *Self) void {
        const priv = self.private();
        const a = alloc();
        if (priv.exec_id) |v| a.free(v);
        if (priv.exec_cmd) |v| a.free(v);
        if (priv.exec_before) |v| a.free(v);
        if (priv.exec_last) |v| a.free(v);
        priv.exec_id = null;
        priv.exec_cmd = null;
        priv.exec_before = null;
        priv.exec_last = null;
        priv.exec_run_btn = null;
        priv.exec_deny_btn = null;
    }

    /// The daemon withdrew a proposal (its turn was replaced): disarm
    /// the buttons. A running command is unaffected.
    fn clearExecProposal(self: *Self) void {
        const priv = self.private();
        if (priv.exec_active) return;
        if (priv.exec_run_btn) |b| b.as(gtk.Widget).setSensitive(0);
        if (priv.exec_deny_btn) |b| b.as(gtk.Widget).setSensitive(0);
        priv.exec_run_btn = null;
        priv.exec_deny_btn = null;
        if (priv.exec_id) |v| alloc().free(v);
        if (priv.exec_cmd) |v| alloc().free(v);
        priv.exec_id = null;
        priv.exec_cmd = null;
    }

    /// Commands that grab the terminal; we never wait long on them and
    /// never feed them input.
    fn isInteractiveCommand(cmd: []const u8) bool {
        var it = std.mem.tokenizeScalar(u8, cmd, ' ');
        const first = it.next() orelse return false;
        const base = std.fs.path.basename(first);
        const tuis = [_][]const u8{
            "vim",   "vi",     "nvim",     "emacs",  "nano",  "joe",
            "ssh",   "telnet", "top",      "htop",   "btop",  "less",
            "more",  "man",    "gdb",      "lldb",   "python", "python3",
            "node",  "irb",    "mysql",    "psql",   "sqlite3", "tmux",
            "screen", "ftp",   "lynx",     "elinks", "mutt",  "alsamixer",
            "nmtui",
        };
        for (tuis) |t| if (std.mem.eql(u8, base, t)) return true;
        return false;
    }

    fn disconnect(self: *Self, note: [:0]const u8) void {
        const priv = self.private();
        if (priv.fd >= 0) {
            _ = close(priv.fd);
        }
        priv.fd = -1;
        priv.ai_turn_open = false;
        priv.exec_active = false;
        priv.open_think = null;
        self.clearExecStrings();
        priv.read_buf.clearRetainingCapacity();
        if (priv.poll_source) |source_id| {
            _ = glib.Source.remove(source_id);
            priv.poll_source = null;
        }
        self.appendText(note);
    }

    //---------------------------------------------------------------
    // UI
    //---------------------------------------------------------------

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();

        // GLib zero-initializes the private area; Zig field defaults are
        // not applied there. A zeroed fd would look like an open socket
        // (fd 0 is stdin), so disconnected must be set explicitly.
        priv.fd = -1;

        priv.tab_id = glib.uuidStringRandom();

        const box = self.as(gtk.Box);
        box.as(gtk.Orientable).setOrientation(.vertical);
        box.setSpacing(6);
        const w = box.as(gtk.Widget);
        w.setMarginTop(6);
        w.setMarginBottom(6);
        w.setMarginStart(6);
        w.setMarginEnd(6);
        // GTK4 has no width-request setter function; set the property.
        var width_value = gobject.ext.Value.newFrom(@as(c_int, 320));
        defer width_value.unset();
        gobject.Object.setProperty(
            w.as(gobject.Object),
            "width-request",
            &width_value,
        );

        // Header. The real panel will replace this with model/provider
        // status for this tab's AI session.
        const header = gtk.Label.new("AI Panel");
        header.as(gtk.Widget).addCssClass("title-4");
        header.setXalign(0);
        box.append(header.as(gtk.Widget));

        // Model picker row: shown once the daemon tells us which
        // providers exist. The choice is per tab.
        const provider_row = gtk.Box.new(.horizontal, 6);
        const provider_label = gtk.Label.new("Model:");
        provider_row.append(provider_label.as(gtk.Widget));
        provider_row.as(gtk.Widget).setVisible(0);
        priv.provider_row = provider_row;
        box.append(provider_row.as(gtk.Widget));

        // Transcript.
        const scroller: *gtk.ScrolledWindow = .new();
        scroller.setPolicy(.automatic, .automatic);
        scroller.as(gtk.Widget).setVexpand(@intFromBool(true));

        const transcript = gtk.TextView.new();
        transcript.setEditable(0);
        transcript.setCursorVisible(0);
        transcript.setMonospace(1);
        transcript.setWrapMode(.word_char);
        priv.transcript = transcript;
        priv.scroller = scroller;

        // Transcript tags. createTag takes (name, property, value)
        // triples terminated by a null property name; booleans go
        // through as C ints in the variadic.
        const buffer = transcript.getBuffer();
        priv.tag_user = buffer.createTag(
            "user_bg",
            "background",
            "rgba(53,132,228,0.30)",
            @as(?[*:0]const u8, null),
        );
        priv.tag_think = buffer.createTag(
            "think_style",
            "italic",
            @as(c_int, 1),
            "foreground-set",
            @as(c_int, 1),
            "foreground",
            "#9a9a9a",
            @as(?[*:0]const u8, null),
        );
        priv.tag_hidden = buffer.createTag(
            "think_hidden",
            "invisible",
            @as(c_int, 1),
            @as(?[*:0]const u8, null),
        );

        scroller.setChild(transcript.as(gtk.Widget));
        box.append(scroller.as(gtk.Widget));

        // Prompt input: a small multiline text view. It grows with its
        // content (propagate-natural-height) up to about five lines and
        // then scrolls, so the text you are typing stays visible even
        // when the panel is narrow: the caret keeps its position and
        // earlier text scrolls sideways as you move back over it.
        // Enter sends; Shift+Enter inserts a newline.
        const input_scroll: *gtk.ScrolledWindow = .new();
        input_scroll.setPolicy(.never, .never);
        input_scroll.setPropagateNaturalHeight(1);
        input_scroll.setMinContentHeight(34);
        input_scroll.setMaxContentHeight(130);

        const input = gtk.TextView.new();
        input.setWrapMode(.word_char);
        priv.input_view = input;
        priv.input_scroll = input_scroll;

        // Placeholder: TextView has none, so lay a dim label over the
        // empty view and hide it whenever there is text.
        const overlay = gtk.Overlay.new();
        const placeholder = gtk.Label.new("Ask the AI about this tab…");
        placeholder.setXalign(0);
        placeholder.as(gtk.Widget).addCssClass("dim-label");
        placeholder.as(gtk.Widget).setCanTarget(0);
        placeholder.as(gtk.Widget).setMarginStart(6);
        placeholder.as(gtk.Widget).setMarginTop(8);
        priv.input_placeholder = placeholder;
        overlay.addOverlay(placeholder.as(gtk.Widget));

        overlay.setChild(input_scroll.as(gtk.Widget));
        input_scroll.setChild(input.as(gtk.Widget));
        box.append(overlay.as(gtk.Widget));

        const ec_in = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(
            ec_in,
            *Self,
            onInputKeyPressed,
            self,
            .{},
        );
        input.as(gtk.Widget).addController(ec_in.as(gtk.EventController));

        // TextBuffer.signals.changed is missing from the bindings'
        // connect structs, so attach it by name.
        _ = gobject.signalConnectData(
            input.getBuffer().as(gobject.Object),
            "changed",
            @ptrCast(&onInputChanged),
            self,
            null,
            .{},
        );

        self.appendText("[ghostty-ai] panel ready\n\n");
    }

    /// Send the input buffer as a chat message.
    fn sendInput(self: *Self) void {
        const priv = self.private();
        const view = priv.input_view orelse return;
        const buffer = view.getBuffer();
        var s: gtk.TextIter = undefined;
        var e: gtk.TextIter = undefined;
        buffer.getBounds(&s, &e);
        const raw = buffer.getText(&s, &e, 0);
        defer glib.free(raw);
        const text = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
        if (text.len == 0) return;
        const owned = glib.ext.dupeZ(u8, text);
        defer glib.free(owned.ptr);
        buffer.setText("", -1);

        // Echo with a blank line before, padded out to the full
        // transcript width so the blue reads as a bar, edge to edge.
        const tbuf = priv.transcript.getBuffer();
        var it: gtk.TextIter = undefined;
        self.append("\n", null);
        tbuf.getEndIter(&it);
        const start_off: usize = @intCast(it.getOffset());
        self.append(owned, priv.tag_user);
        self.padTaggedLine(start_off);
        self.append("\n", priv.tag_user);

        if (!priv.ai_turn_open) self.sendChat(owned);
    }

    /// Enter sends the message; Shift+Enter writes a newline.
    fn onInputKeyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        state: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        if (keyval != gdk.KEY_Return and keyval != gdk.KEY_KP_Enter) return 0;
        if (state.shift_mask) return 0;
        self.sendInput();
        return 1;
    }

    /// Keeps the placeholder in step with the buffer and sizes the
    /// growth cap to exactly five lines of the real font once the text
    /// view has a layout.
    fn onInputChanged(_: *anyopaque, ud: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud));
        const priv = self.private();
        const view = priv.input_view orelse return;
        const buffer = view.getBuffer();

        const empty = buffer.getCharCount() <= 0;
        if (priv.input_placeholder) |ph|
            ph.as(gtk.Widget).setVisible(@intFromBool(empty));

        if (priv.input_line_h <= 0) {
            var it: gtk.TextIter = undefined;
            _ = buffer.getIterAtLine(&it, 0);
            var y: c_int = 0;
            var h: c_int = 0;
            view.getLineYrange(&it, &y, &h);
            if (h > 0) {
                priv.input_line_h = h;
                if (priv.input_scroll) |sc| {
                    sc.setMinContentHeight(h + 12);
                    sc.setMaxContentHeight(h * 5 + 12);
                }
            }
        }
    }

    fn sendChat(self: *Self, text: []const u8) void {
        const priv = self.private();
        if (!self.ensureConnected()) return;
        if (priv.fd < 0) return;

        // Read the visible screen of our own tab as model context.
        var screen: []const u8 = "";
        var screen_owned: ?[]const u8 = null;
        defer if (screen_owned) |s| alloc().free(s);
        if (priv.tab) |tab| {
            if (tab.dumpActiveSurfaceText(alloc())) |s| {
                screen_owned = s;
                screen = s;
            } else |_| {}
        }

        self.sendJson(struct {
            type: []const u8 = "chat",
            text: []const u8,
            screen: []const u8,
        }{ .text = text, .screen = screen });
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();

        // Tell the daemon this tab is gone so it can drop the session.
        if (priv.fd >= 0) {
            self.sendJson(struct {
                type: []const u8 = "bye",
            }{});
        }
        disconnect(self, "");
        if (priv.scroll_soon) |id| _ = glib.Source.remove(id);
        priv.scroll_soon = null;
        if (priv.tab_id) |id| glib.free(id);
        priv.tab_id = null;
        for (priv.provider_names) |n| alloc().free(n);
        priv.provider_names = &.{};
        priv.thinking_blocks.deinit(alloc());
        priv.read_buf.deinit(alloc());

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};
