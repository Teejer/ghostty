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
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern fn localtime(timer: *const i64) callconv(.c) ?*Tm;
extern fn time(arg: ?*anyopaque) callconv(.c) i64;

const TimeVal = extern struct {
    sec: i64,
    usec: i64,
};
extern fn gettimeofday(tv: *TimeVal, tz: ?*anyopaque) callconv(.c) c_int;
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
        ok: bool = false,
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
        dangerous: ?bool = null,
        ok: ?bool = null,
    };

    const Private = struct {
        /// One collapsible "thinking" block in the transcript. The
        /// button is a child anchor inside the TextView; the body text
        /// spans the two marks and is hidden via the shared invisible
        /// tag when collapsed.
        /// A pinned-width child widget in the transcript (pill).
        const Bar = struct {
            w: *gtk.Widget,
            l1: ?*gtk.Label = null,
        };

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

        /// Stats for the in-flight AI turn, shown as an estimated
        /// generation rate in the turn caption's tooltip.
        turn_t0_ms: i64 = 0,
        turn_bytes: usize = 0,

        /// The in-flight AI turn renders into a rounded child label
        /// (same treatment as the user bar); its text is rewritten
        /// with the accumulated answer on every delta, so streaming
        /// stays visible inside the pill.
        ai_label: ?*gtk.Label = null,
        ai_stream: ?[:0]u8 = null,

        /// Text tags: user messages get a blue background; thinking
        /// bodies are italic/dim and additionally invisible when
        /// collapsed.
        tag_think: ?*gtk.TextTag = null,
        tag_hidden: ?*gtk.TextTag = null,

        /// Collapsible thinking blocks; open_think indexes the block
        /// currently receiving reasoning deltas, if any.
        thinking_blocks: std.ArrayList(ThinkingBlock) = .empty,

        /// Child-label bars (message pills, exec pills). Their pinned
        /// width comes from the view width at creation time; the list
        /// lets resizes re-pin them (see syncBarWidths).
        bars: std.ArrayList(Bar) = .empty,
        bar_w: c_int = 0,

        /// Last character appended to the buffer (0 = empty, 'x' =
        /// a child widget followed). Guards block-leading newlines so
        /// content never stacks blank lines.
        last_char: u8 = 0,
        open_think: ?usize = null,

        /// AI-proposed command awaiting this tab's decision (Run/Deny
        /// buttons) or running with output capture (exec_active).
        exec_id: ?[]u8 = null,
        exec_cmd: ?[]u8 = null,
        exec_run_btn: ?*gtk.Button = null,
        exec_deny_btn: ?*gtk.Button = null,
        exec_active: bool = false,
        exec_interactive: bool = false,

        /// Shown once when a slow command passes the soft timeout;
        /// the reply is then held until the screen settles or the
        /// hard timeout (3 min) passes.
        exec_waiting: bool = false,
        exec_before: ?[]u8 = null,
        exec_last: ?[]u8 = null,
        exec_elapsed_ms: u32 = 0,
        exec_stable_ms: u32 = 0,
        exec_tick: u32 = 0,

        /// Post-reply watch: slow commands settle, then print (sleep
        /// && echo) or outlive the timeout. We keep comparing the
        /// screen to what we already sent and push a late exec_output
        /// if it changes and settles.
        follow_active: bool = false,
        follow_id: ?[]u8 = null,
        follow_base: ?[]u8 = null,
        follow_last: ?[]u8 = null,
        follow_ms: u32 = 0,

        /// One-shot scroll timer (see scrollSoon).
        scroll_soon: ?c_uint = null,

        /// Connection status light in the header. dot_class tracks the
        /// css class currently applied so it can be swapped.
        dot: ?*gtk.Label = null,
        dot_class: ?[:0]const u8 = null,

        /// Second light, next to the model dropdown: is the inference
        /// engine (provider endpoint) reachable? And which provider
        /// this tab currently uses, for matching provider_status.
        prov_dot: ?*gtk.Label = null,
        prov_dot_class: ?[:0]const u8 = null,
        cur_provider: ?[]const u8 = null,

        /// Multiline prompt input; the scrolled window caps its growth
        /// at about five lines, and the placeholder label covers the
        /// empty state (TextView has no placeholder of its own).
        input_view: ?*gtk.TextView = null,
        input_scroll: ?*gtk.ScrolledWindow = null,
        input_placeholder: ?*gtk.Label = null,
        input_line_h: c_int = 0,
        input_focused: bool = false,

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
        if (text.len > 0) priv.last_char = text[text.len - 1];

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

        self.setDot("ai-dot-connecting");
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
        self.syncBarWidths();
        if (priv.exec_active or priv.follow_active) self.execPollTick();
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
            self.setDot("ai-dot-ready");
            const old = self.private().cur_provider;
            self.private().cur_provider = alloc().dupe(u8, p) catch null;
            if (old) |o| alloc().free(o);
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
                priv.turn_t0_ms = nowMs();
                priv.turn_bytes = 0;
                self.beginAiTurnLabel();
            }
            const txt: []const u8 = msg.text orelse "";
            priv.turn_bytes += txt.len;
            self.appendToAiTurn(txt);
        } else if (std.mem.eql(u8, msg.type, "done")) {
            self.closeThinkingBlock();
            const priv = self.private();
            if (priv.ai_turn_open) {
                priv.ai_turn_open = false;
                self.endAiTurn();
                if (stamp()) |hm| {
                    defer alloc().free(hm);
                    self.appendTurnCaption(hm);
                }
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
                    "auto-run: {s}",
                    .{cmd},
                    0,
                ) catch return;
                defer alloc().free(auto_note);
                self.appendExecBar(auto_note);
                self.startExec(id, cmd);
            } else {
                self.closeThinkingBlock();
                if (self.private().ai_turn_open) {
                    self.private().ai_turn_open = false;
                    self.endAiTurn();
                }
                self.appendExecProposal(id, cmd, msg.dangerous orelse false);
            }
        } else if (std.mem.eql(u8, msg.type, "exec_cancel")) {
            self.clearExecProposal();
        } else if (std.mem.eql(u8, msg.type, "provider_status")) {
            const cur = self.private().cur_provider orelse "";
            if (std.mem.eql(u8, msg.provider orelse "", cur))
                self.setProviderDot(msg.ok orelse false);
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
            // Insert before the light so a provider switch (which
            // rebuilds the dropdown but not the light) keeps the row
            // order [label, dropdown, light].
            row.append(drop.as(gtk.Widget));
            if (priv.prov_dot) |pd|
                row.reorderChildAfter(
                    pd.as(gtk.Widget),
                    drop.as(gtk.Widget),
                );

            // Engine light beside the picker: green when the daemon
            // can reach this endpoint, dim when it cannot.
            if (priv.prov_dot == null) {
                const pd = gtk.Label.new("\u{25cf}");
                pd.as(gtk.Widget).addCssClass("ai-dot");
                priv.prov_dot = pd;
                row.append(pd.as(gtk.Widget));
            }
            var ok_now = false;
            for (infos) |inf| {
                if (std.mem.eql(u8, inf.name, current)) ok_now = inf.ok;
            }
            self.setProviderDot(ok_now);

            row.as(gtk.Widget).setVisible(1);
        }
    }

    /// Swap the provider light's state class.
    fn setProviderDot(self: *Self, ok: bool) void {
        const priv = self.private();
        const dot = (priv.prov_dot orelse return).as(gtk.Widget);
        const state: [:0]const u8 = if (ok) "ai-dot-ready" else "ai-dot-off";
        if (priv.prov_dot_class) |old| dot.removeCssClass(old);
        dot.addCssClass(state);
        priv.prov_dot_class = state;
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

        self.nl();
        var iter: gtk.TextIter = undefined;
        buffer.getEndIter(&iter);
        const anchor = buffer.createChildAnchor(&iter);

        const button = gtk.Button.newWithLabel("thinking ▸");
        button.as(gtk.Widget).addCssClass("flat");
        button.as(gtk.Widget).addCssClass("ai-thinking");
        button.as(gtk.Widget).addCssClass("caption");
        _ = gtk.Button.signals.clicked.connect(
            button,
            *Self,
            onThinkingToggled,
            self,
            .{},
        );
        priv.transcript.addChildAtAnchor(button.as(gtk.Widget), anchor);
        priv.last_char = '\n';

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
        // Left gravity, like the start mark: a right-gravity mark at
        // the buffer end slides right with every later insertion, so
        // collapsing would hide everything appended since (including
        // the exec Run/Deny anchors).
        blk.end = buffer.createMark(null, &e, 1);
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
                button.setLabel("thinking ▾");
            } else {
                buffer.applyTag(priv.tag_hidden.?, &s, &e);
                blk.hidden = true;
                button.setLabel("thinking ▸");
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
    /// One amber pill: the proposed command and its Approve/Deny
    /// buttons share a single rounded background (separate bars for
    /// text and buttons read as two misaligned boxes).
    fn appendExecProposal(
        self: *Self,
        id: []const u8,
        cmd: []const u8,
        dangerous: bool,
    ) void {
        const priv = self.private();
        const a = alloc();
        self.clearExecProposal();

        const buffer = priv.transcript.getBuffer();
        self.nl();
        var iter: gtk.TextIter = undefined;
        buffer.getEndIter(&iter);
        const anchor = buffer.createChildAnchor(&iter);

        const outer = gtk.Box.new(.vertical, 4);
        outer.as(gtk.Widget).addCssClass("ai-exec");
        if (dangerous) outer.as(gtk.Widget).addCssClass("ai-exec-warn");

        const text = if (dangerous)
            std.fmt.allocPrintSentinel(
                a,
                "\u{26a0} dangerous \u{2014} run: {s}",
                .{cmd},
                0,
            )
        else
            std.fmt.allocPrintSentinel(a, "Run: {s}", .{cmd}, 0);
        const textz = text catch return;
        defer a.free(textz);
        const label = gtk.Label.new(textz);
        label.setXalign(0);
        label.setWrap(1);
        label.setSelectable(1);
        outer.append(label.as(gtk.Widget));

        const buttons = gtk.Box.new(.horizontal, 6);
        const run = gtk.Button.newWithLabel("Approve");
        run.as(gtk.Widget).addCssClass(if (dangerous)
            "destructive-action"
        else
            "suggested-action");
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
        buttons.append(run.as(gtk.Widget));
        buttons.append(deny.as(gtk.Widget));
        outer.append(buttons.as(gtk.Widget));

        priv.transcript.addChildAtAnchor(outer.as(gtk.Widget), anchor);
        self.trackBar(outer.as(gtk.Widget), label);

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

        self.clearFollow();
        const tab = priv.tab orelse {
            self.execReply(id, "failed", "");
            return;
        };
        log.debug("exec approved, injecting id={s}", .{id});
        if (!tab.injectText(w.written())) {
            self.appendExecBar("exec failed: no active surface");
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
        priv.exec_waiting = false;
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

        const tab = priv.tab orelse {
            if (priv.exec_active) self.finishExec("failed", "");
            self.clearFollow();
            return;
        };
        const after = tab.dumpActiveSurfaceText(a) catch {
            if (priv.exec_active) self.finishExec("failed", "");
            return;
        };
        defer a.free(after);

        if (priv.exec_active) {
            priv.exec_elapsed_ms += 300;
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
            const min_age_ms: u32 = if (priv.exec_interactive) 1_500 else 2_000;
            if (priv.exec_stable_ms >= settle_ms and priv.exec_elapsed_ms >= min_age_ms) {
                self.finishExec("done", after);
            } else if (priv.exec_interactive) {
                if (priv.exec_elapsed_ms >= timeout_ms)
                    self.finishExec("interactive", after);
            } else if (priv.exec_elapsed_ms >= 180_000) {
                // Hard cap: still answer with what we have.
                self.finishExec("timeout", after);
            } else if (priv.exec_elapsed_ms >= timeout_ms and !priv.exec_waiting) {
                // Soft timeout: keep watching and say so in the
                // panel. The model only ever sees the settled screen,
                // so it never has to complain about missing output.
                priv.exec_waiting = true;
                self.appendExecBar("waiting for the command to finish…");
            }
            return;
        }
        self.followTick(after);
    }

    /// Post-reply watch, ~300ms cadence. If the screen diverges from
    /// what we already sent and then settles, the command kept
    /// working (or finished quietly); push the fresh screen as
    /// exec_output and stop. Giving up after 60s unchanged / 120s
    /// unstable keeps a chatty shell from keeping the watch forever.
    fn followTick(self: *Self, after: []const u8) void {
        const priv = self.private();
        const a = alloc();
        priv.follow_ms += 300;

        const base = priv.follow_base orelse {
            self.clearFollow();
            return;
        };
        if (std.mem.eql(u8, base, after)) {
            if (priv.follow_ms >= 60_000) self.clearFollow();
            return;
        }

        const stable = priv.follow_last != null and
            std.mem.eql(u8, priv.follow_last.?, after);
        if (priv.follow_last) |v| a.free(v);
        priv.follow_last = a.dupe(u8, after) catch null;
        if (!stable) {
            if (priv.follow_ms >= 120_000) self.clearFollow();
            return;
        }

        const id = priv.follow_id orelse {
            self.clearFollow();
            return;
        };
        const from = if (after.len > 8192) after.len - 8192 else 0;
        log.debug("exec follow-up output id={s} bytes={d}", .{ id, after.len });
        self.sendJson(struct {
            type: []const u8 = "exec_output",
            id: []const u8,
            output: []const u8,
        }{ .id = id, .output = after[from..] });
        self.clearFollow();
    }

    fn clearFollow(self: *Self) void {
        const priv = self.private();
        const a = alloc();
        if (priv.follow_id) |v| a.free(v);
        if (priv.follow_base) |v| a.free(v);
        if (priv.follow_last) |v| a.free(v);
        priv.follow_id = null;
        priv.follow_base = null;
        priv.follow_last = null;
        priv.follow_ms = 0;
        priv.follow_active = false;
    }

    /// Shell-integration completion event for a surface in this tab:
    /// authoritative "a command finished". Ends an in-flight capture
    /// immediately (the exit code becomes the reply status) and
    /// flushes a pending follow-up watch without the settle delay.
    /// Manual commands the user runs fire this too; they are ignored
    /// while nothing is being captured.
    pub fn execPromptDone(self: *Self, exit_code: ?u8) void {
        const priv = self.private();
        if (!priv.exec_active and !priv.follow_active) return;
        const tab = priv.tab orelse return;
        const after = tab.dumpActiveSurfaceText(alloc()) catch return;
        defer alloc().free(after);

        if (priv.exec_active) {
            var buf: [24]u8 = undefined;
            const status: []const u8 = if (exit_code) |code| blk: {
                break :blk if (code == 0) "done" else
                    std.fmt.bufPrint(&buf, "exit {d}", .{code}) catch "done";
            } else "done";
            self.finishExec(status, after);
            return;
        }

        // Follow-up watch: the shell just proved the screen settled.
        const base = priv.follow_base orelse return;
        if (std.mem.eql(u8, base, after)) return;
        const id = priv.follow_id orelse return;
        const from = if (after.len > 8192) after.len - 8192 else 0;
        log.debug("exec follow-up output (prompt event) id={s}", .{id});
        self.sendJson(struct {
            type: []const u8 = "exec_output",
            id: []const u8,
            output: []const u8,
        }{ .id = id, .output = after[from..] });
        self.clearFollow();
    }

    fn finishExec(self: *Self, status: []const u8, output: []const u8) void {
        const priv = self.private();
        const id = priv.exec_id orelse return;
        // The screen tail is what just ran: command, output, prompt.
        const from = if (output.len > 8192) output.len - 8192 else 0;
        log.debug("exec finished status={s} output_bytes={}", .{ status, output.len });
        self.execReply(id, status, output[from..]);
        if (std.mem.eql(u8, status, "timeout")) {
            self.appendExecBar("exec: still running; sent the model the output so far");
        } else if (std.mem.eql(u8, status, "interactive")) {
            self.appendExecBar("exec: looks interactive; sent partial output, will not drive it");
        }
        priv.exec_active = false;

        // Keep watching after done/timeout replies (not interactive:
        // there the screen changes because the user is driving it).
        const watch = std.mem.eql(u8, status, "done") or
            std.mem.eql(u8, status, "timeout");
        const follow_id = if (watch) (alloc().dupe(u8, id) catch null) else null;
        const follow_base = if (watch) (alloc().dupe(u8, output) catch null) else null;
        self.clearExecStrings();
        if (watch and follow_id != null and follow_base != null) {
            priv.follow_active = true;
            priv.follow_id = follow_id;
            priv.follow_base = follow_base;
            priv.follow_ms = 0;
        } else {
            if (follow_id) |v| alloc().free(v);
            if (follow_base) |v| alloc().free(v);
        }
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

    /// Swap the header connection light's state class.
    fn setDot(self: *Self, state: [:0]const u8) void {
        const priv = self.private();
        const dot = (priv.dot orelse return).as(gtk.Widget);
        if (priv.dot_class) |old| dot.removeCssClass(old);
        dot.addCssClass(state);
        priv.dot_class = state;
    }

    fn disconnect(self: *Self, note: [:0]const u8) void {
        const priv = self.private();
        if (priv.fd >= 0) {
            _ = close(priv.fd);
        }
        priv.fd = -1;
        self.setDot("ai-dot-off");
        priv.ai_turn_open = false;
        self.endAiTurn();
        priv.exec_active = false;
        priv.open_think = null;
        self.clearExecStrings();
        self.clearFollow();
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

        // Dot colors. Display-scoped so one provider serves all panels.
        const css =
            \\label.ai-dot { font-size: 10px; margin-top: 6px; }
            \\label.ai-dot-off { color: alpha(currentColor, 0.30); }
            \\label.ai-dot-connecting { color: #e5b567; }
            \\label.ai-dot-ready { color: #4ec970; }
            \\label.ai-msg {
            \\    background: rgba(53,132,228,0.30);
            \\    border-radius: 8px;
            \\    padding: 2px 8px;
            \\}
            \\.ai-turn {
            \\    background: rgba(0,0,0,0.28);
            \\    border-radius: 8px;
            \\    padding: 2px 8px;
            \\}
            \\.ai-exec {
            \\    background: rgba(229,181,103,0.22);
            \\    border-radius: 8px;
            \\    padding: 4px 8px;
            \\}
            \\.ai-exec button,
            \\button.ai-thinking {
            \\    cursor: pointer;
            \\}
            \\.ai-exec-warn {
            \\    background: rgba(213,80,80,0.30);
            \\}
            \\.ai-time {
            \\    font-size: 0.62em;
            \\}
            \\button.ai-thinking {
            \\    font-size: 0.75em;
            \\    min-height: 0;
            \\    min-width: 0;
            \\    padding: 0 4px;
            \\}
        ;
        const provider = gtk.CssProvider.new();
        provider.loadFromData(css.ptr, @intCast(css.len));
        if (gdk.Display.getDefault()) |display| gtk.StyleContext.addProviderForDisplay(
            display,
            provider.as(gtk.StyleProvider),
            gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
        box.setSpacing(6);
        const w = box.as(gtk.Widget);
        w.setMarginTop(6);
        w.setMarginBottom(6);
        w.setMarginStart(6);
        w.setMarginEnd(6);
        // No width-request here on purpose: a minimum on the panel
        // root is a trap. GtkPaned cannot shrink the end child below
        // its minimum, so once the window is narrower than
        // terminal_min + minimum the panel spills off the window's
        // right edge and the overflow silently eats the right side
        // of every pill and caption. The initial width comes from
        // the paned position timer in tab.zig instead.

        // Header: title plus a connection light. Green = session
        // ready, amber = socket open but no hello reply yet, dim =
        // disconnected. Replaces the startup chatter lines.
        const header_row = gtk.Box.new(.horizontal, 6);
        const header = gtk.Label.new("AI Panel");
        header.as(gtk.Widget).addCssClass("title-4");
        header.setXalign(0);
        header.as(gtk.Widget).setHexpand(1);
        const dot = gtk.Label.new("●");
        dot.as(gtk.Widget).addCssClass("ai-dot");
        dot.as(gtk.Widget).addCssClass("ai-dot-off");
        priv.dot = dot;
        header_row.append(header.as(gtk.Widget));
        header_row.append(dot.as(gtk.Widget));
        box.append(header_row.as(gtk.Widget));

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
        // Vertical policy must be automatic: with .never the scroller
        // ignores propagate-natural-height and the min/max caps and
        // requests the whole content height, pushing the input past
        // the window bottom. Horizontal stays never because the view
        // word-wraps instead.
        input_scroll.setPolicy(.never, .automatic);
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

        // Placeholder behaves like entry placeholder text: hidden while
        // focused or non-empty, back only when blurred and empty.
        placeholder.as(gtk.Widget).setValign(.start);
        const ec_focus = gtk.EventControllerFocus.new();
        _ = gtk.EventControllerFocus.signals.enter.connect(
            ec_focus,
            *Self,
            onInputFocusIn,
            self,
            .{},
        );
        _ = gtk.EventControllerFocus.signals.leave.connect(
            ec_focus,
            *Self,
            onInputFocusOut,
            self,
            .{},
        );
        input.as(gtk.Widget).addController(ec_focus.as(gtk.EventController));

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

    }

    /// Unix epoch milliseconds; 0 if the syscall fails.
    fn nowMs() i64 {
        var tv: TimeVal = undefined;
        if (gettimeofday(&tv, null) < 0) return 0;
        return tv.sec * 1000 + @divTrunc(tv.usec, 1000);
    }

    /// "HH:MM" local time, for message arrival stamps.
    fn stamp() ?[:0]u8 {
        var t: i64 = time(null);
        if (t < 0) return null;
        const tm = localtime(&t) orelse return null;
        // Unsigned: 0.17's formatter force-signs c_int values
        // ("+17"). Verified with zig run.
        return std.fmt.allocPrintSentinel(
            alloc(),
            "{d:0>2}:{d:0>2}",
            .{
                @as(u32, @intCast(tm.hour)),
                @as(u32, @intCast(tm.min)),
            },
            0,
        ) catch null;
    }

    fn pinWidgetWidth(w: *gtk.Widget, target: c_int) void {
        var value = gobject.ext.Value.newFrom(target);
        defer value.unset();
        gobject.Object.setProperty(
            w.as(gobject.Object),
            "width-request",
            &value,
        );
    }

    /// Re-cap every bar when the view width changed; called from the
    /// 300ms daemon poll.
    fn syncBarWidths(self: *Self) void {
        const priv = self.private();
        const wpx = priv.transcript.as(gtk.Widget).getAllocatedWidth();
        if (wpx <= 60 or wpx == priv.bar_w) return;
        priv.bar_w = wpx;
        for (priv.bars.items) |bar| {
            if (bar.l1) |lbl| Self.pinWidgetWidth(
                lbl.as(gtk.Widget),
                wpx - 14,
            );
            Self.pinWidgetWidth(bar.w, wpx - 14);
        }
    }

    /// Register a bar, pin it to the current view width, and mark the
    /// buffer position as "widget line" so the next block still gets
    /// its own newline.
    fn trackBar(self: *Self, w: *gtk.Widget, label: ?*gtk.Label) void {
        const priv = self.private();
        priv.bars.append(alloc(), .{ .w = w, .l1 = label }) catch {};
        priv.last_char = 'x';
        const wpx = priv.transcript.as(gtk.Widget).getAllocatedWidth();
        if (wpx > 60) {
            if (label) |lbl| Self.pinWidgetWidth(
                lbl.as(gtk.Widget),
                wpx - 14,
            );
            Self.pinWidgetWidth(w, wpx - 14);
        }
    }

    /// Newline before a block, unless the buffer already ends on one.
    fn nl(self: *Self) void {
        const priv = self.private();
        if (priv.last_char != '\n') self.append("\n", null);
    }

    /// User message bar: the blue pill, with the arrival time as a
    /// small dim caption on the line below it.
    fn appendMsgBar(self: *Self, text: [:0]const u8, hm: ?[:0]const u8) void {
        const priv = self.private();
        const tbuf = priv.transcript.getBuffer();
        var it: gtk.TextIter = undefined;
        tbuf.getEndIter(&it);
        const anchor = tbuf.createChildAnchor(&it);

        const row = gtk.Box.new(.vertical, 0);
        const label = gtk.Label.new(text);
        label.setXalign(0);
        label.setWrap(1);
        label.setSelectable(1);
        label.as(gtk.Widget).addCssClass("ai-msg");
        row.append(label.as(gtk.Widget));

        if (hm) |t| {
            const lbl = gtk.Label.new(t);
            lbl.setXalign(1);
            lbl.as(gtk.Widget).addCssClass("caption");
            lbl.as(gtk.Widget).addCssClass("dim-label");
            lbl.as(gtk.Widget).addCssClass("ai-time");
            row.append(lbl.as(gtk.Widget));
        }

        priv.transcript.addChildAtAnchor(row.as(gtk.Widget), anchor);
        self.trackBar(row.as(gtk.Widget), label);
    }

    /// Anchor a fresh rounded pill for the turn's answer text.
    fn beginAiTurnLabel(self: *Self) void {
        const priv = self.private();
        const tbuf = priv.transcript.getBuffer();
        self.nl();
        var it: gtk.TextIter = undefined;
        tbuf.getEndIter(&it);
        const anchor = tbuf.createChildAnchor(&it);

        const label = gtk.Label.new("");
        label.setXalign(0);
        label.setWrap(1);
        label.setSelectable(1);
        label.as(gtk.Widget).addCssClass("ai-turn");
        priv.transcript.addChildAtAnchor(label.as(gtk.Widget), anchor);
        self.trackBar(label.as(gtk.Widget), label);
        priv.ai_label = label;
    }

    /// Rewrite the pill with the accumulated answer. A few dozen KB
    /// of re-set per turn is nothing next to the render it replaces.
    fn appendToAiTurn(self: *Self, txt: []const u8) void {
        const priv = self.private();
        const a = alloc();
        const label = priv.ai_label orelse return;
        const prev: []const u8 = priv.ai_stream orelse "";
        const next = std.fmt.allocPrintSentinel(
            a,
            "{s}{s}",
            .{ prev, txt },
            0,
        ) catch return;
        if (priv.ai_stream) |old| a.free(old);
        priv.ai_stream = next;
        label.setText(next.ptr);
        // Child widgets do not trigger the buffer's insert-scroll,
        // so keep the view pinned while the pill grows.
        self.scrollSoon();
    }

    /// Turn text is final (answer done, or an exec proposal cutting
    /// it short); drop the streaming references, keep the label.
    fn endAiTurn(self: *Self) void {
        const priv = self.private();
        const a = alloc();
        if (priv.ai_stream) |st| {
            // Models routinely end answers with blank lines; inside a
            // pill that reads as a layout bug, so trim the tail.
            var end_i: usize = st.len;
            while (end_i > 0 and std.ascii.isWhitespace(st[end_i - 1]))
                end_i -= 1;
            const trimmed = st[0..end_i];
            if (trimmed.len != st.len) {
                if (priv.ai_label) |lbl| {
                    if (std.fmt.allocPrintSentinel(a, "{s}", .{trimmed}, 0)) |z| {
                        lbl.setText(z.ptr);
                        a.free(z);
                    } else |_| {}
                }
            }
            a.free(st);
        }
        priv.ai_stream = null;
        priv.ai_label = null;
    }

    fn appendTurnCaption(self: *Self, hm: [:0]const u8) void {
        const priv = self.private();
        const a = alloc();
        const tbuf = priv.transcript.getBuffer();
        self.nl();
        var it: gtk.TextIter = undefined;
        tbuf.getEndIter(&it);
        const anchor = tbuf.createChildAnchor(&it);

        const label = gtk.Label.new(hm);
        label.as(gtk.Widget).addCssClass("ai-time");
        label.setXalign(0);
        label.as(gtk.Widget).addCssClass("caption");
        label.as(gtk.Widget).addCssClass("dim-label");

        const ms: i64 = @max(1, nowMs() -% priv.turn_t0_ms);
        const tokens = priv.turn_bytes / 4;
        const rate = tokens * 1000 / @as(u64, @intCast(ms));
        if (std.fmt.allocPrintSentinel(
            a,
            "~{d} tokens in ~{d} ms · ~{d} tok/s",
            .{ tokens, ms, rate },
            0,
        )) |tip| {
            defer a.free(tip);
            label.as(gtk.Widget).setTooltipText(tip);
        } else |_| {}

        priv.transcript.addChildAtAnchor(label.as(gtk.Widget), anchor);
    }

    /// A rounded, full-width child-label bar. Text tags can only paint
    /// hard rectangles, so transcript highlights that want css (corner
    /// radius, padding) are anchored widgets. Width is requested from
    /// the current view width; old bars keep their width across
    /// resizes.
    fn appendBar(self: *Self, text: [:0]const u8, css_class: [:0]const u8) void {
        const priv = self.private();
        const tbuf = priv.transcript.getBuffer();
        var it: gtk.TextIter = undefined;
        tbuf.getEndIter(&it);
        const anchor = tbuf.createChildAnchor(&it);
        const bar = gtk.Label.new(text);
        bar.setXalign(0);
        bar.setWrap(1);
        bar.setSelectable(1);
        bar.as(gtk.Widget).addCssClass(css_class);
        priv.transcript.addChildAtAnchor(bar.as(gtk.Widget), anchor);
        self.trackBar(bar.as(gtk.Widget), bar);
    }

    /// A standalone amber exec-status line.
    fn appendExecBar(self: *Self, text: [:0]const u8) void {
        self.nl();
        self.appendBar(text, "ai-exec");
        self.append("\n", null);
        self.scrollSoon();
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

        // Echo as a rounded full-width bar. Tag backgrounds can only
        // paint hard rectangles, so the message is a child-anchored
        // label styled with css; it also makes sent messages
        // selectable. Width-request spans the view so the bar reaches
        // the edges (computed at write time; old bars keep their
        // width across resizes, as with the old padding trick).
        const hm = stamp();
        defer if (hm) |v| alloc().free(v);

        self.nl();
        self.appendMsgBar(owned, hm);
        self.append("\n", null);
        self.scrollSoon();

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

    fn onInputFocusIn(
        _: *gtk.EventControllerFocus,
        self: *Self,
    ) callconv(.c) void {
        self.private().input_focused = true;
        self.refreshPlaceholder();
    }

    fn onInputFocusOut(
        _: *gtk.EventControllerFocus,
        self: *Self,
    ) callconv(.c) void {
        self.private().input_focused = false;
        self.refreshPlaceholder();
    }

    fn refreshPlaceholder(self: *Self) void {
        const priv = self.private();
        const ph = priv.input_placeholder orelse return;
        const view = priv.input_view orelse return;
        const empty = view.getBuffer().getCharCount() <= 0;
        ph.as(gtk.Widget).setVisible(@intFromBool(empty and !priv.input_focused));
    }

    /// Keeps the placeholder in step with the buffer and sizes the
    /// growth cap to exactly five lines of the real font once the text
    /// view has a layout.
    fn onInputChanged(_: *anyopaque, ud: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud));
        const priv = self.private();
        const view = priv.input_view orelse return;
        const buffer = view.getBuffer();

        self.refreshPlaceholder();

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
        if (priv.cur_provider) |v| alloc().free(v);
        priv.cur_provider = null;
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
