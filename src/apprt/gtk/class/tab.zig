const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Allocator = std.mem.Allocator;
const configpkg = @import("../../../config.zig");
const apprt = @import("../../../apprt.zig");
const CoreSurface = @import("../../../Surface.zig");
const global = @import("../../../global.zig");
const terminal = @import("../../../terminal/main.zig");
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const AiPanel = @import("ai_panel.zig").AiPanel;
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const SplitTree = @import("split_tree.zig").SplitTree;
const Surface = @import("surface.zig").Surface;
const TitleDialog = @import("title_dialog.zig").TitleDialog;
const Overrides = @import("Overrides.zig");

const log = std.log.scoped(.gtk_ghostty_window);

pub const Tab = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyTab",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the surface that should be receiving all
        /// surface-targeted actions. This is usually the focused surface,
        /// but may also not be focused if the user has selected a non-surface
        /// widget.
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{
                            .getter = Self.getActiveSurface,
                        },
                    ),
                },
            );
        };

        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const @"split-tree" = struct {
            pub const name = "split-tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*SplitTree,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*SplitTree,
                        .{
                            .getter = getSplitTree,
                        },
                    ),
                },
            );
        };

        pub const @"surface-tree" = struct {
            pub const name = "surface-tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface.Tree,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface.Tree,
                        .{
                            .getter = getSurfaceTree,
                        },
                    ),
                },
            );
        };

        pub const tooltip = struct {
            pub const name = "tooltip";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("tooltip"),
                },
            );
        };

        pub const title = struct {
            pub const name = "title";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title"),
                },
            );
        };
        pub const @"title-override" = struct {
            pub const name = "title-override";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title_override"),
                },
            );
        };
    };

    pub const signals = struct {
        /// Emitted whenever the tab would like to be closed.
        pub const @"close-request" = struct {
            pub const name = "close-request";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
    };

    const Private = struct {
        /// The configuration that this surface is using.
        config: ?*Config = null,

        /// The title of this tab. This is usually bound to the active surface.
        title: ?[:0]const u8 = null,

        /// The manually overridden title.
        title_override: ?[:0]const u8 = null,

        /// The tooltip of this tab. This is usually bound to the active surface.
        tooltip: ?[:0]const u8 = null,

        // Template bindings
        split_tree: *SplitTree,

        /// The right-docked AI panel and the paned which docks it next
        /// to the split tree. See initAiPanel.
        ai_paned: ?*gtk.Paned = null,
        ai_panel: ?*AiPanel = null,

        /// True once the AI panel has been shown and given its initial
        /// position. We only set the position on first show so that we
        /// do not clobber a manual resize when toggling the panel.
        ai_panel_positioned: bool = false,

        /// Repeating timer that positions an auto-opened panel once the
        /// tab has a width (tabs are constructed before allocation).
        ai_position_timer: ?c_uint = null,

        pub var offset: c_int = 0;
    };

    /// Set the parent of this tab page. This only affects the first surface
    /// ever created for a tab. If a surface was already created this does
    /// nothing.
    pub fn setParent(self: *Self, parent: *CoreSurface) void {
        self.setParentWithContext(parent, .tab);
    }

    pub fn setParentWithContext(self: *Self, parent: *CoreSurface, context: apprt.surface.NewSurfaceContext) void {
        if (self.getActiveSurface()) |surface| {
            surface.setParent(parent, context);
        }
    }

    pub fn new(config: ?*Config, overrides: Overrides) *Self {
        const tab = gobject.ext.newInstance(Tab, .{});

        const priv: *Private = tab.private();

        if (config) |c| priv.config = c.ref();

        // If our configuration is null then we get the configuration
        // from the application.
        if (priv.config == null) {
            const app = Application.default();
            priv.config = app.getConfig();
        }

        tab.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);

        // Create our initial surface in the split tree.
        priv.split_tree.newSplit(.right, null, .{
            .command = overrides.command,
            .shell_integration = overrides.shell_integration,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
        }) catch |err| switch (err) {
            error.OutOfMemory => {
                // TODO: We should make our "no surfaces" state more aesthetically
                // pleasing and show something like an "Oops, something went wrong"
                // message. For now, this is incredibly unlikely.
                @panic("oom");
            },
        };

        return tab;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Init our actions
        self.initActionMap();

        // Init our right-docked AI panel.
        self.initAiPanel();
    }

    /// Build the right-docked AI panel. The tab template parents split_tree
    /// directly inside the tab box, so we reparent it into a paned with the
    /// panel as the other child. We do this in code instead of editing the
    /// blueprint template so that the upstream UI files stay untouched; the
    /// templates property bindings reference the split_tree object itself,
    /// so reparenting does not affect them.
    fn initAiPanel(self: *Self) void {
        const priv = self.private();
        const box = self.as(gtk.Box);

        // Reparent the split tree into the paned. We hold a temporary ref
        // across the remove so the widget survives the unparent.
        const split_tree = priv.split_tree.as(gtk.Widget);
        _ = split_tree.ref();
        box.remove(split_tree);

        const paned = gtk.Paned.new(.horizontal);
        // On window resize the terminal (start child) absorbs the size
        // change and the panel keeps its width; the user drags the
        // handle when they want the panel to change.
        paned.setResizeStartChild(1);
        paned.setResizeEndChild(0);
        paned.setShrinkStartChild(0);
        paned.setShrinkEndChild(1);
        paned.setWideHandle(1);
        paned.setStartChild(split_tree);
        _ = split_tree.unref();

        // Floor the terminal side at ~40 columns. bash redraws its
        // prompt at every SIGWINCH, and once the prompt wraps (pane
        // narrower than the prompt) the redraws pile up as partial
        // prompt fragments in scrollback — reproducible in stock
        // ghostty with splits, so it is shell behavior, but the
        // divider should never let a surface get that small.
        // setShrinkStartChild(0) then keeps the paned honest about
        // this minimum.
        var min_width = gobject.ext.Value.newFrom(@as(c_int, 320));
        defer min_width.unset();
        gobject.Object.setProperty(
            split_tree.as(gobject.Object),
            "width-request",
            &min_width,
        );

        // Create the panel but keep it hidden until toggled. GtkPaned hides
        // the handle when the end child is invisible, so a hidden panel
        // looks exactly like the stock layout.
        const panel = AiPanel.new();
        panel.setTab(self);
        panel.as(gtk.Widget).setVisible(0);
        paned.setEndChild(panel.as(gtk.Widget));
        box.append(paned.as(gtk.Widget));

        priv.ai_paned = paned;
        priv.ai_panel = panel;

        // Skeleton keybinding: ctrl+alt+i toggles this tab's panel. We hook
        // it on the tab in the capture phase so it fires before the focused
        // surface sees the key. This is temporary plumbing until the panel
        // gets a proper Ghostty keybind action.
        const ec_key = gtk.EventControllerKey.new();
        ec_key.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(
            ec_key,
            *Self,
            aiPanelKeyPressed,
            self,
            .{},
        );
        self.as(gtk.Widget).addController(ec_key.as(gtk.EventController));

        // Fork preference: show the panel from the start. The tab has
        // no size yet, so a short timer applies the initial split as
        // soon as the paned has been allocated.
        const app = Application.default();
        const conf = app.getConfig();
        defer conf.unref();
        if (conf.get().@"ai-panel-default-open") {
            panel.as(gtk.Widget).setVisible(1);
            _ = panel.ensureConnected();
            priv.ai_position_timer = glib.timeoutAdd(
                200,
                aiPanelPositionTick,
                self,
            );
        }
    }

    /// Positions an auto-opened panel at its initial split once the
    /// tab has a width. Self-stopping: returns 0 when done, disabled,
    /// or positioned elsewhere.
    fn aiPanelPositionTick(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud));
        const priv = self.private();
        priv.ai_position_timer = null;
        if (priv.ai_panel_positioned) return 0;
        const panel = (priv.ai_panel orelse return 0).as(gtk.Widget);
        if (panel.getVisible() == 0) return 0;
        const paned = priv.ai_paned orelse return 0;
        const width = paned.as(gtk.Widget).getWidth();
        if (width <= 0) {
            priv.ai_position_timer = glib.timeoutAdd(200, aiPanelPositionTick, self);
            return 0;
        }
        priv.ai_panel_positioned = true;
        paned.setPosition(@intCast(@divTrunc(width * 2, 3)));
        return 0;
    }

    /// Toggle this tabs AI panel visibility.
    pub fn toggleAiPanel(self: *Self) void {
        const priv = self.private();
        const panel = (priv.ai_panel orelse return).as(gtk.Widget);
        if (panel.getVisible() != 0) {
            panel.setVisible(0);
            return;
        }

        panel.setVisible(1);

        // Connect on show so the model picker and connection state
        // appear without requiring a first message.
        if (priv.ai_panel) |panel_obj| {
            _ = panel_obj.ensureConnected();
        }

        // On first show, give the panel a third of the tab (position is
        // the width of the start child, i.e. the terminal).
        if (priv.ai_paned) |paned| {
            if (!priv.ai_panel_positioned) {
                const width = paned.as(gtk.Widget).getWidth();
                if (width > 0) {
                    priv.ai_panel_positioned = true;
                    paned.setPosition(@intCast(@divTrunc(width * 2, 3)));
                }
            }
        }
    }

    /// Shell integration reported a command completion on one of this
    /// tab's surfaces. If the AI panel is capturing output for an
    /// approved command, this is the authoritative done event; the
    /// panel finishes immediately with the exit code instead of
    /// waiting for the screen to look stable.
    pub fn aiCommandFinished(self: *Self, exit_code: ?u8) void {
        if (self.private().ai_panel) |panel| panel.execPromptDone(exit_code);
    }

    /// Read the visible screen text of this tabs active surface. This is
    /// the core read path that lets the AI panel see the contents of its
    /// own tab and only its own tab. The returned string is allocated
    /// with the given allocator and owned by the caller.
    pub fn dumpActiveSurfaceText(
        self: *Self,
        alloc: Allocator,
    ) ![]const u8 {
        const gtk_surface = (self.getActiveSurface()) orelse
            return error.NoActiveSurface;
        const core = gtk_surface.core() orelse return error.NoActiveSurface;

        // The renderer state mutex must be held to read terminal state.
        // We hold it only long enough to copy out the text, never across
        // anything slow like network I/O.
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());

        // The core's own screen dump, same as the inspector and tests:
        // ".active" is the visible screen without scrollback.
        return try core.renderer_state.terminal.screens.active
            .dumpStringAlloc(alloc, .{ .active = .{} });
    }

    /// The active surface's working directory as tracked by shell
    /// integration (OSC 7), if known. Sent with each chat message so
    /// the daemon can find per-project instruction files.
    pub fn activeSurfacePwd(
        self: *Self,
        alloc: Allocator,
    ) !?[]const u8 {
        const gtk_surface = (self.getActiveSurface()) orelse
            return null;
        const core = gtk_surface.core() orelse return null;
        return core.pwd(alloc) catch null;
    }

    /// Scrollback text of the active surface: the `.screen` dump
    /// includes the page history, unlike the `.active` dump. Tail-
    /// limited to max_lines lines and 64 KiB so a huge buffer cannot
    /// flood the daemon socket.
    pub fn dumpActiveSurfaceScrollback(
        self: *Self,
        alloc: Allocator,
        max_lines: usize,
    ) ![]const u8 {
        const gtk_surface = (self.getActiveSurface()) orelse
            return error.NoActiveSurface;
        const core = gtk_surface.core() orelse
            return error.NoActiveSurface;

        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());

        const all = try core.renderer_state.terminal.screens.active
            .dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(all);

        // Walk back to the start of the newest max_lines lines.
        var lines: usize = 0;
        var start: usize = 0;
        var i: usize = all.len;
        while (i > 0) {
            i -= 1;
            if (all[i] == '\n') {
                if (lines == max_lines) {
                    start = i + 1;
                    break;
                }
                lines += 1;
            }
        }
        const tail = all[start..];
        const from = if (tail.len > 64 * 1024)
            tail.len - 64 * 1024
        else
            0;
        return try alloc.dupe(u8, tail[from..]);
    }

    /// Inject raw text into the active surface's pty, exactly what the
    /// "write" keybinding action does (no bracketed paste). The AI
    /// panel may only call this after the user approved the command;
    /// the text must be escaped the way config "write:" strings are
    /// (backslashes doubled, "\n" for Enter).
    pub fn injectText(self: *Self, text: []const u8) bool {
        const gtk_surface = (self.getActiveSurface()) orelse return false;
        const core = gtk_surface.core() orelse return false;
        _ = core.performBindingAction(.{ .text = text }) catch |err| {
            log.warn("ai inject text failed err={}", .{err});
            return false;
        };
        return true;
    }

    fn aiPanelKeyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        state: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        // ctrl+alt+i
        if (!state.control_mask or !state.alt_mask) return 0;
        if (keyval != gdk.KEY_i) return 0;
        self.toggleAiPanel();
        return 1;
    }

    fn initActionMap(self: *Self) void {
        const s_param_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_param_type.free();

        const actions = [_]ext.actions.Action(Self){
            .init("close", actionClose, s_param_type),
            .init("ring-bell", actionRingBell, null),
            .init("next-page", actionNextPage, null),
            .init("previous-page", actionPreviousPage, null),
            .init("prompt-tab-title", actionPromptTabTitle, null),
            .init("toggle-ai-panel", actionToggleAiPanel, null),
        };

        _ = ext.actions.addAsGroup(Self, self, "tab", &actions);
    }

    //---------------------------------------------------------------
    // Properties

    /// Overridden title. This will be generally be shown over the title
    /// unless this is unset (null).
    pub fn setTitleOverride(self: *Self, title: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.title_override) |v| glib.free(@ptrCast(@constCast(v)));
        priv.title_override = null;
        if (title) |v| priv.title_override = glib.ext.dupeZ(u8, v);
        self.as(gobject.Object).notifyByPspec(properties.@"title-override".impl.param_spec);
    }
    fn titleDialogSet(
        _: *TitleDialog,
        title_ptr: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        const title = std.mem.span(title_ptr);
        self.setTitleOverride(if (title.len == 0) null else title);
    }
    pub fn promptTabTitle(self: *Self) void {
        const priv = self.private();
        const dialog = TitleDialog.new(.tab, priv.title_override orelse priv.title);
        _ = TitleDialog.signals.set.connect(
            dialog,
            *Self,
            titleDialogSet,
            self,
            .{},
        );

        dialog.present(self.as(gtk.Widget));
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        return self.getSplitTree().getActiveSurface();
    }

    /// Get the surface tree of this tab.
    pub fn getSurfaceTree(self: *Self) ?*Surface.Tree {
        const priv = self.private();
        return priv.split_tree.getTree();
    }

    /// Get the split tree widget that is in this tab.
    pub fn getSplitTree(self: *Self) *SplitTree {
        const priv = self.private();
        return priv.split_tree;
    }

    /// Returns true if this tab needs confirmation before quitting based
    /// on the various Ghostty configurations.
    pub fn getNeedsConfirmQuit(self: *Self) bool {
        const tree = self.getSplitTree();
        return tree.getNeedsConfirmQuit();
    }

    /// Get the tab view holding this tab, if any.
    fn getTabView(self: *Self) ?*adw.TabView {
        return ext.getAncestor(
            adw.TabView,
            self.as(gtk.Widget),
        );
    }

    /// Get the tab page holding this tab, if any.
    fn getTabPage(self: *Self) ?*adw.TabPage {
        const tab_view = self.getTabView() orelse return null;
        return tab_view.getPage(self.as(gtk.Widget));
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.ai_position_timer) |source_id| {
            _ = glib.Source.remove(source_id);
            priv.ai_position_timer = null;
        }
        if (priv.tooltip) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.tooltip = null;
        }
        if (priv.title) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title = null;
        }
        if (priv.title_override) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title_override = null;
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }
    //---------------------------------------------------------------
    // Signal handlers

    fn propSplitTree(
        _: *SplitTree,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.as(gobject.Object).notifyByPspec(properties.@"surface-tree".impl.param_spec);

        // If our tree is empty we close the tab.
        const tree: *const Surface.Tree = self.getSurfaceTree() orelse &.empty;
        if (tree.isEmpty()) {
            signals.@"close-request".impl.emit(
                self,
                null,
                .{},
                null,
            );
            return;
        }
    }

    fn propActiveSurface(
        _: *SplitTree,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    fn actionClose(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const param = param_ orelse {
            log.warn("tab.close-tab called without a parameter", .{});
            return;
        };

        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);

        const tab_view = self.getTabView() orelse return;
        const page = tab_view.getPage(self.as(gtk.Widget));

        const mode = std.meta.stringToEnum(
            apprt.action.CloseTabMode,
            std.mem.span(
                str orelse {
                    log.warn("invalid mode provided to tab.close-tab", .{});
                    return;
                },
            ),
        ) orelse {
            // Need to be defensive here since actions can be triggered externally.
            log.warn("invalid mode provided to tab.close-tab: {s}", .{str.?});
            return;
        };

        // Delegate to our parent to handle this, since this will emit
        // a close-page signal that the parent can intercept.
        switch (mode) {
            .this => tab_view.closePage(page),
            .other => tab_view.closeOtherPages(page),
            .right => tab_view.closePagesAfter(page),
        }
    }

    fn actionPromptTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.promptTabTitle();
    }

    fn actionToggleAiPanel(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.toggleAiPanel();
    }

    fn actionRingBell(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        // Future note: I actually don't like this logic living here at all.
        // I think a better approach will be for the ring bell action to
        // specify its sending surface and then do all this in the window.

        // If the page is selected already we don't mark it as needing
        // attention. We only want to mark unfocused pages. This will then
        // clear when the page is selected.
        const page = self.getTabPage() orelse return;
        if (page.getSelected() != 0) return;
        page.setNeedsAttention(@intFromBool(true));
    }

    /// Select the next tab page.
    fn actionNextPage(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const tab_view = self.getTabView() orelse return;
        _ = tab_view.selectNextPage();
    }

    /// Select the previous tab page.
    fn actionPreviousPage(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const tab_view = self.getTabView() orelse return;
        _ = tab_view.selectPreviousPage();
    }

    fn closureComputedTitle(
        _: *Self,
        config_: ?*Config,
        terminal_: ?[*:0]const u8,
        surface_override_: ?[*:0]const u8,
        tab_override_: ?[*:0]const u8,
        zoomed_: c_int,
        bell_ringing_: c_int,
        _: *gobject.ParamSpec,
    ) callconv(.c) ?[*:0]const u8 {
        const zoomed = zoomed_ != 0;
        const bell_ringing = bell_ringing_ != 0;

        // Our plain title is the manually tab overridden title if it exists,
        // otherwise the overridden title if it exists, otherwise
        // the terminal title if it exists, otherwise a default string.
        const plain = plain: {
            const default = "Ghostty";
            const config_title: ?[*:0]const u8 = title: {
                const config = config_ orelse break :title null;
                break :title config.get().title orelse null;
            };

            const plain = tab_override_ orelse
                surface_override_ orelse
                terminal_ orelse
                config_title orelse
                break :plain default;
            break :plain std.mem.span(plain);
        };

        // We don't need a config in every case, but if we don't have a config
        // let's just assume something went terribly wrong and use our
        // default title. Its easier then guarding on the config existing
        // in every case for something so unlikely.
        const config = if (config_) |v| v.get() else {
            log.warn("config unavailable for computed title, likely bug", .{});
            return glib.ext.dupeZ(u8, plain);
        };

        // Use an allocator to build up our string as we write it.
        var buf: std.Io.Writer.Allocating = .init(Application.default().allocator());
        defer buf.deinit();

        // If our bell is ringing, then we prefix the bell icon to the title.
        if (bell_ringing and config.@"bell-features".title) {
            buf.writer.writeAll("🔔 ") catch {};
        }

        // If we're zoomed, prefix with the magnifying glass emoji.
        if (zoomed) {
            buf.writer.writeAll("🔍 ") catch {};
        }

        buf.writer.writeAll(plain) catch return glib.ext.dupeZ(u8, plain);
        return glib.ext.dupeZ(u8, buf.written());
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
            gobject.ext.ensureType(SplitTree);
            gobject.ext.ensureType(Surface);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 0,
                    .name = "tab",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.config.impl,
                properties.@"split-tree".impl,
                properties.@"surface-tree".impl,
                properties.title.impl,
                properties.@"title-override".impl,
                properties.tooltip.impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("split_tree", .{});

            // Template Callbacks
            class.bindTemplateCallback("computed_title", &closureComputedTitle);
            class.bindTemplateCallback("notify_active_surface", &propActiveSurface);
            class.bindTemplateCallback("notify_tree", &propSplitTree);

            // Signals
            signals.@"close-request".impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
