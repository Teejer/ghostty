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
                self.appendText("\n\n");
            }
        } else if (std.mem.eql(u8, msg.type, "error")) {
            self.closeThinkingBlock();
            const priv = self.private();
            priv.ai_turn_open = false;
            self.appendText("\n[ghostty-ai error] ");
            self.appendSlice(msg.message orelse "unknown error");
            self.appendText("\n\n");
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

    fn disconnect(self: *Self, note: [:0]const u8) void {        const priv = self.private();
        if (priv.fd >= 0) {
            _ = close(priv.fd);
        }
        priv.fd = -1;
        priv.ai_turn_open = false;
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
            "style-italic",
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

        // Prompt entry.
        const entry = gtk.Entry.new();
        entry.setPlaceholderText("Ask the AI about this tab…");
        _ = gtk.Entry.signals.activate.connect(
            entry,
            *Self,
            onEntryActivate,
            self,
            .{},
        );
        box.append(entry.as(gtk.Widget));

        self.appendText("[ghostty-ai] panel ready\n\n");
    }

    fn onEntryActivate(
        entry: *gtk.Entry,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const text = std.mem.span(entry.as(gtk.Editable).getText());
        if (text.len == 0) return;

        // One echo line so the blue background covers the whole
        // message, prefix included.
        var w: std.Io.Writer.Allocating = .init(alloc());
        defer w.deinit();
        w.writer.print("you: {s}\n", .{text}) catch return;
        self.append(w.written(), priv.tag_user);
        entry.as(gtk.Editable).setText("");

        if (!priv.ai_turn_open) self.sendChat(text);
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
