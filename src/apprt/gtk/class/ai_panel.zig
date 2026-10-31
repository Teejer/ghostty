//! The per-tab AI panel docked to the right side of each tab.
//!
//! This is the skeleton: it proves the per-tab docked layout and gives
//! us a place to build the real chat UI, the connection to the ghostty-ai
//! daemon, and the terminal-interaction controls in later steps. Each
//! panel belongs to exactly one tab and its lifetime is tied to it.

const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;

pub const AiPanel = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyAiPanel",
        .instanceInit = &init,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// Chat transcript shown to the user.
        transcript: *gtk.TextView = undefined,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    /// Append text to the chat transcript.
    pub fn appendText(self: *Self, text: [:0]const u8) void {
        const priv = self.private();
        const buffer = priv.transcript.getBuffer();
        var iter: gtk.TextIter = undefined;
        buffer.getEndIter(&iter);
        buffer.insert(&iter, text, -1);

        // Keep the newest text visible.
        buffer.getEndIter(&iter);
        const mark = buffer.getMark("insert").?;
        buffer.moveMark(mark, &iter);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();

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

        scroller.setChild(transcript.as(gtk.Widget));
        box.append(scroller.as(gtk.Widget));

        // Prompt entry. For now this just echoes into the transcript so we
        // can verify per-tab event plumbing; it will send to the daemon
        // once the connection layer exists.
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

        self.appendText("[ghostty-ai] panel ready (skeleton)\n\n");
    }

    fn onEntryActivate(
        entry: *gtk.Entry,
        self: *Self,
    ) callconv(.c) void {
        const text = std.mem.span(entry.as(gtk.Editable).getText());

        self.appendText("you: ");
        self.appendText(text);
        self.appendText("\n(ai backend not connected yet)\n\n");

        entry.as(gtk.Editable).setText("");
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
        pub const as = C.Class.as;
    };
};
