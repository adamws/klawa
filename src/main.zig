const clap = @import("clap");
const rl = @import("raylib");
const rgui = @import("raygui");
const std = @import("std");
const fs = std.fs;
const known_folders = @import("known-folders");
const KnownFolder = known_folders.KnownFolder;

const builtin = @import("builtin");
const debug = (builtin.mode == std.builtin.OptimizeMode.Debug);

const config = @import("config.zig");
const kle = @import("kle.zig");
const math = @import("math.zig");
const tracy = @import("tracy.zig");
const x11 = @import("x11.zig");

const labels_lookup = @import("layout_labels.zig").labels_lookup;
const symbols_lookup = @import("symbols_lookup.zig").symbols_lookup;

const Ffmpeg = @import("ffmpeg.zig").Ffmpeg;
const Layout = @import("layout.zig").Layout;
const SpscQueue = @import("spsc_queue.zig").SpscQueue;

const gl = struct {
    pub const PixelFormat = enum(c_uint) {
        rgba = 0x1908,
    };
    pub const PixelType = enum(c_uint) {
        unsigned_byte = 0x1401,
    };

    // these should be exported in libraylib.a:
    pub extern "c" fn glReadPixels(x: c_int, y: c_int, width: c_int, height: c_int, format: PixelFormat, @"type": PixelType, data: [*c]u8) void;
    pub const readPixels = glReadPixels;
};

pub const known_folders_config = .{
    .xdg_on_mac = true,
};

pub const Theme = enum {
    default,
    kle,
    vortex_pok3r,

    const keycaps_default_data = @embedFile("resources/keycaps_default_atlas.png");
    const keycaps_kle_data = @embedFile("resources/keycaps_kle_with_gaps_atlas.png");
    const keycaps_vortex_pok3r_data = @embedFile("resources/keycaps_vortex_pok3r_atlas.png");

    pub fn getData(self: Theme) []const u8 {
        return switch (self) {
            .default => keycaps_default_data,
            .kle => keycaps_kle_data,
            .vortex_pok3r => keycaps_vortex_pok3r_data,
        };
    }

    pub fn fromString(value: []const u8) ?Theme {
        return std.meta.stringToEnum(Theme, value);
    }
};

const ConfigData = struct {
    window_undecorated: bool = true,
    typing_font_size: i32 = 120,
    typing_font_color: u32 = 0x000000ff, // alpha=1
    layout_preset: []const u8 = "tkl_ansi",
    layout_path: []const u8 = "", // absolute or realative to config file
    theme: []const u8 = "default",
    show_typing: bool = true,
    key_tint_color: u32 = 0xff0000ff, // alpha=1
};

const KeyOnScreen = struct {
    src: rl.Rectangle,
    dst: rl.Rectangle,
    angle: f32,
    pressed: bool,
};

const CodepointBuffer = struct {
    write_index: Index = 0,
    data: [capacity]i32 = .{0} ** capacity,

    const capacity = 32; // must be power of 2
    const IndexBits = std.math.log2_int(usize, capacity);
    const Index = std.meta.Int(.unsigned, IndexBits);

    pub fn push(self: *CodepointBuffer, value: i32) void {
        self.data[self.write_index] = value;
        self.write_index = self.write_index +% 1;
    }

    pub const Iterator = struct {
        queue: *CodepointBuffer,
        count: Index,

        pub fn next(it: *Iterator) ?i32 {
            it.count = it.count -% 1;
            if (it.count == it.queue.write_index) return null;
            const cp = it.queue.data[it.count];
            if (cp == 0) return null;
            return cp;
        }
    };

    pub fn iterator(self: *CodepointBuffer) Iterator {
        return Iterator{
            .queue = self,
            .count = self.write_index,
        };
    }
};

pub var app_state: AppState = undefined;

// https://github.com/bits/UTF-8-Unicode-Test-Documents/blob/master/UTF-8_sequence_unseparated/utf8_sequence_0-0xfff_assigned_printable_unseparated.txt
const text = @embedFile("resources/utf8_sequence_0-0xfff_assigned_printable_unseparated.txt");

const symbols = "↚↹⏎␣⌫↑←→↓ᴷᴾ⏎";
const all_text = text ++ symbols;

// it contains all current sumstitutions symbols:
// TODO: font discovery with fallbacks when glyph not found
// TODO: support for non-monospaced fonts
const font_data = @embedFile("resources/DejaVuSansMono.ttf");

pub const AppState = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(kle.Keyboard),
    keyboard: kle.Keyboard,
    key_states: []KeyOnScreen,
    keycode_keyboard_lookup: [256]i32,
    window_width: c_int,
    window_height: c_int,
    keys: Queue = Queue.init(),
    last_char_timestamp: i64 = 0,

    const Queue = SpscQueue(32, x11.KeyData);
    const KEY_1U_PX = 64;

    pub fn init(allocator: std.mem.Allocator, parsed: std.json.Parsed(kle.Keyboard)) !AppState {
        var self: AppState = .{
            .allocator = allocator,
            .parsed = parsed,
            .keyboard = parsed.value,
            .key_states = try allocator.alloc(KeyOnScreen, parsed.value.keys.len),
            .keycode_keyboard_lookup = .{-1} ** 256,
            .window_width = -1,
            .window_height = -1,
        };
        initKeys(&self);
        try calculateKeyLookup(&self);
        calcualteWindoWize(&self);
        return self;
    }

    fn initKeys(self: *AppState) void {
        for (self.keyboard.keys, 0..) |k, index| {
            var s = &self.key_states[index];

            const angle_rad = std.math.rad_per_deg * k.rotation_angle;
            const point = math.Vec2{ .x = k.x, .y = k.y };
            const rot_origin = math.Vec2{ .x = k.rotation_x, .y = k.rotation_y };
            const result = math.rotate_around_center(point, rot_origin, angle_rad);

            const width: f32 = @floatCast(KEY_1U_PX * @max(k.width, k.width2));
            const height: f32 = @floatCast(KEY_1U_PX * @max(k.height, k.height2));

            s.src = rl.Rectangle{
                .x = 0,
                .y = @floatCast(KEY_1U_PX * (k.width * 4 - 4)),
                .width = width,
                .height = height,
            };
            s.dst = rl.Rectangle{
                .x = @floatCast(KEY_1U_PX * result.x),
                .y = @floatCast(KEY_1U_PX * result.y),
                .width = width,
                .height = height,
            };
            s.angle = @floatCast(k.rotation_angle);

            // special case: iso enter
            // TODO: calculate, not hardcode
            if (k.width == 1.25 and k.width2 == 1.5 and k.height == 2 and k.height2 == 1) {
                s.src.x = 0;
                s.src.y = 1824;
                s.dst.x -= 0.25 * KEY_1U_PX;
            } else if (k.width == 1.0 and k.height == 2.0) {
                s.src.x = 0;
                s.src.y = 1824 - 128;
            } else if (k.width == 1.0 and k.height == 1.5) {
                s.src.x = 0;
                s.src.y = 1824 - 128 - 64 - 32;
            }

            s.pressed = false;
        }
    }

    fn calculateKeyLookup(self: *AppState) !void {
        var universal_key_label: [128]u8 = undefined;
        for (self.keyboard.keys, 0..) |key, index| {
            for (key.labels) |maybe_label| {
                if (maybe_label) |label| {
                    var iter = std.mem.split(u8, label, ",");
                    while (iter.next()) |part| {
                        const key_label = try std.fmt.bufPrint(&universal_key_label, "KC_{s}", .{part});
                        const key_code = labels_lookup.get(key_label) orelse 0;
                        self.keycode_keyboard_lookup[@as(usize, key_code)] = @intCast(index);
                    }
                }
            }
        }
    }

    fn calcualteWindoWize(self: *AppState) void {
        const bbox = self.calculateBoundingBox();
        self.window_width = @intFromFloat(bbox.w * KEY_1U_PX);
        self.window_height = @intFromFloat(bbox.h * KEY_1U_PX);
        std.debug.print("Window size: {}x{}\n", .{ self.window_width, self.window_height });
    }

    fn calculateBoundingBox(self: AppState) struct { x: f64, y: f64, w: f64, h: f64 } {
        var max_x: f64 = 0;
        var max_y: f64 = 0;
        for (self.keyboard.keys) |k| {
            const angle = k.rotation_angle;
            if (angle != 0) {
                const angle_rad = std.math.rad_per_deg * angle;
                const rot_origin = kle.Point{ .x = k.rotation_x, .y = k.rotation_y };

                // when rotated, check each corner
                const x1 = k.x;
                const x2 = k.x + k.width;
                const y1 = k.y;
                const y2 = k.y + k.height;
                const corners = [4]kle.Point {
                    .{ .x = x1, .y = y1 },
                    .{ .x = x2, .y = y1 },
                    .{ .x = x1, .y = y2 },
                    .{ .x = x2, .y = y2 },
                };

                for (corners) |p| {
                    const rotated = math.rotate_around_center(p, rot_origin, angle_rad);

                    if (rotated.x >= max_x) max_x = rotated.x;
                    if (rotated.y >= max_y) max_y = rotated.y;
                }
            } else {
                //when not rotated, it is safe to check only bottom right corner:
                const x = k.x + k.width;
                const y = k.y + k.height;
                if (x >= max_x) max_x = x;
                if (y >= max_y) max_y = y;
            }
        }
        // note: always start at (0, 0).
        // we do not support layout shifting
        return .{ .x = 0, .y = 0, .w = max_x, .h = max_y };
    }

    pub fn updateKeyStates(self: *AppState, keycode: usize, pressed: bool) void {
        const lookup: i32 = self.keycode_keyboard_lookup[keycode];
        if (lookup >= 0) {
            const index: usize = @intCast(lookup);
            self.key_states[index].pressed = pressed;
        }
    }

    pub fn deinit(self: *AppState) void {
        self.parsed.deinit();
        self.allocator.free(self.key_states);
        self.* = undefined;
    }
};

fn getState(allocator: std.mem.Allocator, config_path: []const u8, layout_path: []const u8, layout: Layout) !AppState {
    const kle_str: []const u8 = blk: {
        if (layout_path.len != 0) {
            std.debug.print("layout = {s}\n", .{layout_path});
            var dir = try fs.cwd().openDir(config_path, .{});
            defer dir.close();
            var layout_file = try dir.openFile(layout_path, .{});
            break :blk try layout_file.readToEndAlloc(allocator, 4096);
        } else {
            break :blk try allocator.dupe(u8, layout.getData());
        }
    };
    defer allocator.free(kle_str);

    const keyboard = try kle.parseFromSlice(allocator, kle_str);
    return AppState.init(allocator, keyboard);
}

test "bounding box" {
    const cases = [_]struct {
        layout: []const u8,
        expected: struct { w: c_int, h: c_int },
    }{
        .{
            .layout = @embedFile("resources/layouts/60_iso.json"),
            .expected = .{ .w = 960, .h = 320 },
        },

        //.{
        //    .layout = @embedFile("test_data/ansi-104.json"),
        //    .expected = .{ .w = 1440, .h = 416 },
        //},
        //.{
        //    .layout = @embedFile("test_data/atreus.json"),
        //    .expected = .{ .w = 812, .h = 345 },
        //},
    };

    const allocator = std.testing.allocator;

    for (cases) |case| {
        const parsed = try kle.parseFromSlice(allocator, case.layout);

        var s = try AppState.init(allocator, parsed);
        defer s.deinit();

        try std.testing.expect(s.window_width == case.expected.w);
        try std.testing.expect(s.window_height == case.expected.h);
    }
}

fn loadTexture(theme: Theme) rl.Texture {
    const keycaps = theme.getData();
    const keycaps_image = rl.loadImageFromMemory(".png", keycaps);
    const keycap_texture = rl.loadTextureFromImage(keycaps_image);
    rl.setTextureFilter(keycap_texture, rl.TextureFilter.texture_filter_bilinear);
    // texture created, image no longer needed
    rl.unloadImage(keycaps_image);
    return keycap_texture;
}

pub fn main() !void {
    const trace_ = tracy.trace(@src());
    defer trace_.end();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cwd = fs.cwd();

    const params = comptime clap.parseParamsComptime(
        \\    --record <str>     Record events to file.
        \\    --replay <str>     Replay events from file.
        \\    --replay-loop      Loop replay action. When not set app will exit after replay ends.
        \\    --render <str>     Render frames to video file. Works only with replay without loop.
        \\-h, --help             Display this help and exit.
        \\
    );

    var res = try clap.parse(clap.Help, &params, clap.parsers.default, .{ .allocator = allocator });
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{
            .spacing_between_parameters = 0,
        });
    }

    // argument validation

    if (res.args.replay) |replay_file| {
        // just checking if it exist
        const f = try cwd.openFile(replay_file, .{});
        f.close();
    }

    // config handling

    const config_path = blk: {
        const executable_dir = try known_folders.getPath(allocator, .executable_dir) orelse unreachable;
        defer allocator.free(executable_dir);
        std.debug.print("executable_dir {s}\n", .{executable_dir});

        // use '\0' terminated alloc because this will be passed to inotify syscalls (in c)
        var conf = try std.fmt.allocPrintZ(allocator, "{s}/config", .{executable_dir});
        if (cwd.openFile(conf, .{})) |file| {
            file.close();
            std.debug.print("Use config file from executable directory\n", .{});
            break :blk conf;
        } else |_| {
            allocator.free(conf);

            // check in local configuration dir
            const local_configuration_dir = try known_folders.getPath(allocator, .local_configuration) orelse unreachable;
            defer allocator.free(local_configuration_dir);
            std.debug.print("local_configuration_dir {s}\n", .{local_configuration_dir});

            conf = try std.fmt.allocPrintZ(allocator, "{s}/klawa/config", .{local_configuration_dir});
            break :blk conf;
        }
    };
    defer allocator.free(config_path);

    const config_dir = fs.path.dirname(config_path) orelse "";

    var app_config = config.configManager(ConfigData, allocator);
    defer app_config.deinit();

    _ = app_config.loadFromFile(config_path) catch |err| switch (err) {
        error.ConfigNotFound => std.debug.print("Default builtin config\n", .{}),
        else => return err,
    };

    // this option is not hot-reloadable yet:
    const typing_font_size = app_config.data.typing_font_size;

    var typing_font_color: rl.Color = rl.Color.fromInt(app_config.data.typing_font_color);
    var key_tint_color: rl.Color = rl.Color.fromInt(app_config.data.key_tint_color);

    var config_watch = try config.Watch.init(config_path);
    defer config_watch.deinit();

    var layout = Layout.fromString(app_config.data.layout_preset) orelse Layout.tkl_ansi;

    app_state = blk: {
        const layout_path = app_config.data.layout_path;
        break :blk try getState(allocator, config_dir, layout_path, layout);
    };
    defer app_state.deinit();

    const number_of_layouts = std.enums.values(Layout).len;
    var layout_index: usize = @intFromEnum(layout);
    var reload_layout_gui: bool = false;

    // window creation

    rl.setConfigFlags(.{ .msaa_4x_hint = true, .vsync_hint = true, .window_highdpi = true });
    rl.initWindow(app_state.window_width, app_state.window_height, "klawa");
    defer rl.closeWindow();

    rl.setWindowState(.{ .window_undecorated = app_config.data.window_undecorated });
    rl.setExitKey(rl.KeyboardKey.key_null);

    const app_window = x11.getX11Window(@ptrCast(rl.getWindowHandle()));
    std.debug.print("Application x11 window handle: 0x{X}\n", .{app_window});

    // TODO: is this even needed?
    rl.setTargetFPS(60);

    var renderer: ?Ffmpeg = null;
    var pixels: ?[]u8 = null;
    if (res.args.render) |dst| {
        // TODO: check if ffmpeg installed
        renderer = try Ffmpeg.spawn(@intCast(app_state.window_width), @intCast(app_state.window_height), dst, allocator);
        pixels = try allocator.alloc(u8, @as(usize, @intCast(app_state.window_width * app_state.window_height)) * 4);
    }
    defer if (pixels) |p| allocator.free(p);

    var thread: ?std.Thread = null;
    if (res.args.replay) |replay_file| {
        // TODO: this will start processing events before rendering ready, add synchronization
        const loop = res.args.@"replay-loop" != 0;
        thread = try std.Thread.spawn(.{}, x11.producer, .{ &app_state, app_window, replay_file, loop });
    } else {
        // TODO: assign to thread var when close supported, join on this thread won't work now
        _ = try std.Thread.spawn(.{}, x11.listener, .{ &app_state, app_window, res.args.record });
    }
    defer if (thread) |t| {
        t.join();
    };

    var keycap_texture = blk: {
        const theme = Theme.fromString(app_config.data.theme) orelse unreachable;
        break :blk loadTexture(theme);
    };
    defer rl.unloadTexture(keycap_texture);

    // TODO: implement font discovery
    // TODO: if not found fallback to default
    const codepoints = try rl.loadCodepoints(all_text);
    defer rl.unloadCodepoints(codepoints);

    std.debug.print("Text contains {} codepoints\n", .{codepoints.len});

    // TODO: font should be configurable
    const font = rl.loadFontFromMemory(".ttf", font_data, typing_font_size, codepoints);
    const default_font = rl.getFontDefault();

    const typing_glyph_size = rl.getGlyphAtlasRec(font, 0);
    const typing_glyph_width: c_int = @intFromFloat(typing_glyph_size.width);

    var exit_window = false;
    var show_gui = false;

    const exit_label = "Exit Application";
    const exit_text_width = rl.measureText(exit_label, default_font.baseSize);

    const typing_persistance_sec = 2;

    var codepoints_buffer = CodepointBuffer{};

    while (!exit_window) {
        if (rl.windowShouldClose()) {
            exit_window = true;
        }

        if (rl.isMouseButtonPressed(rl.MouseButton.mouse_button_right)) {
            std.debug.print("Toggle settings\n", .{});
            show_gui = !show_gui;
        }

        // TODO: handle errors
        if (try config_watch.checkForChanges()) {
            std.debug.print("Config file change detected\n", .{});
            const changes = try app_config.loadFromFile(config_path);
            var iter = changes.iterator();
            while (iter.next()) |v| switch(v) {
                .window_undecorated => {
                    rl.setWindowState(.{ .window_undecorated = app_config.data.window_undecorated });
                },
                .layout_path, .layout_preset => {
                    const layout_path = app_config.data.layout_path;
                    layout = Layout.fromString(app_config.data.layout_preset) orelse Layout.tkl_ansi;
                    if (layout_path.len != 0) {
                        std.debug.print("Reload layout using file '{s}'\n", .{layout_path});
                    } else {
                        std.debug.print("Reload layout using preset '{s}'\n", .{@tagName(layout)});
                    }
                    if (getState(allocator, config_dir, app_config.data.layout_path, layout)) |new_state| {
                        app_state.deinit();
                        app_state = new_state;
                        rl.setWindowSize(app_state.window_width, app_state.window_height);
                    } else |err| switch (err) {
                        error.FileNotFound => std.debug.print("Layout file not found, reload aborted\n", .{}),
                        else => unreachable,
                    }
                },
                .theme => {
                    std.debug.print("Reload theme to '{s}'\n", .{app_config.data.theme});
                    if (Theme.fromString(app_config.data.theme)) |new_theme| {
                        keycap_texture = blk: {
                            rl.unloadTexture(keycap_texture);
                            break :blk loadTexture(new_theme);
                        };
                    } else {
                        std.debug.print("Got unrecognized theme: '{s}', reload aborted\n", .{app_config.data.theme});
                    }
                },
                .key_tint_color => key_tint_color = rl.Color.fromInt(app_config.data.key_tint_color),
                .typing_font_color => typing_font_color = rl.Color.fromInt(app_config.data.typing_font_color),
                else => {},
            };
        }

        if (reload_layout_gui) {
            reload_layout_gui = false;

            layout = try std.meta.intToEnum(Layout, layout_index);
            std.debug.print("Reload layout using preset '{s}'\n", .{@tagName(layout)});
            if (getState(allocator, config_dir, "", layout)) |new_state| {
                app_state.deinit();
                app_state = new_state;
                rl.setWindowSize(app_state.window_width, app_state.window_height);
            } else |err| switch (err) {
                error.FileNotFound => std.debug.print("Layout file not found, reload aborted\n", .{}),
                else => unreachable,
            }
        }

        if (app_state.keys.pop()) |k| {
            if (k.symbol == null) continue;
            std.debug.print("Consumed: '{s}'\n", .{k.symbol});

            var text_: [*:0]const u8 = undefined;

            if (symbols_lookup.get(std.mem.sliceTo(k.symbol, 0))) |symbol| {
                std.debug.print("Replacement: '{s}'\n", .{symbol});
                text_ = symbol;
            } else {
                text_ = @ptrCast(&k.string);
            }

            if (rl.loadCodepoints(text_)) |codepoints_| {
                for (codepoints_) |cp| {
                    codepoints_buffer.push(cp);
                    std.debug.print("codepoints: '{any}'\n", .{codepoints_buffer});
                }
            } else |_| {}
        }

        rl.beginDrawing();
        // TODO: background color should be configurable
        // TODO: research window transparency
        rl.clearBackground(rl.Color.black);

        const rot = rl.Vector2{ .x = 0, .y = 0 };

        for (app_state.key_states) |k| {
            var dst = k.dst;
            if (k.pressed) dst.y += 5;
            const tint = if (k.pressed) key_tint_color else rl.Color.white;
            rl.drawTexturePro(keycap_texture, k.src, dst, rot, k.angle, tint);
        }

        if (app_config.data.show_typing and
            std.time.timestamp() - app_state.last_char_timestamp <= typing_persistance_sec) {
            rl.drawRectangle(
                0,
                @divTrunc(app_state.window_height - typing_font_size, 2),
                app_state.window_width,
                typing_font_size,
                rl.Color{ .r = 0, .g = 0, .b = 0, .a = 128 },
            );

            var offset: c_int = 0;
            var it = codepoints_buffer.iterator();
            while (it.next()) |cp| {
                rl.drawTextCodepoint(
                    font,
                    cp,
                    .{
                        .x = @floatFromInt(@divTrunc(app_state.window_width - typing_glyph_width, 2) - offset),
                        .y = @floatFromInt(@divTrunc(app_state.window_height - typing_font_size, 2)),
                    },
                    @floatFromInt(typing_font_size),
                    typing_font_color,
                );
                offset += typing_glyph_width + 20;
            }
        }

        // would prefer native controls in separate window, this gui is temporary:
        if (show_gui) {
            rl.drawRectangle(
                0,
                0,
                app_state.window_width,
                app_state.window_height,
                rl.Color{ .r = 255, .g = 255, .b = 255, .a = 196 },
            );

            // previous layout
            if (1 == rgui.guiButton(
                .{
                    .x = 48,
                    .y = 16,
                    .width = 16,
                    .height = 16,
                },
                "#118#",
            )) {
                layout_index = if (layout_index == 0) number_of_layouts - 1 else layout_index - 1;
                std.debug.print("Set previous layout: {}\n", .{layout_index});
                reload_layout_gui = true;
            }
            // next layout
            if (1 == rgui.guiButton(
                .{
                    .x = 48 + 8 + 16,
                    .y = 16,
                    .width = 16,
                    .height = 16,
                },
                "#119#",
            )) {
                layout_index = if (layout_index == number_of_layouts - 1) 0 else layout_index + 1;
                std.debug.print("Set next layout: {}\n", .{layout_index});
                reload_layout_gui = true;
            }
            var layout_label_buf: [2048]u8 = undefined;
            const layout_label = try std.fmt.bufPrintZ(&layout_label_buf, "Layout: {s}", .{@tagName(layout)});
            _ = rgui.guiLabel(
                .{
                    .x = 48 + 8 + 16 + 16 + 8,
                    .y = 16,
                    .width = 256,
                    .height = 16,
                },
                layout_label,
            );

            if (1 == rgui.guiButton(
                .{
                    .x = @floatFromInt(app_state.window_width - 48 - exit_text_width),
                    .y = 16,
                    .width = @floatFromInt(32 + exit_text_width),
                    .height = 32,
                },
                std.fmt.comptimePrint("#113#{s}", .{exit_label}),
            )) {
                exit_window = true;
            }
        }

        if (debug) {
            rl.drawFPS(10, 10);
        }
        rl.endDrawing();
        tracy.frameMark();

        if (renderer) |*r| {
            const rendering = tracy.traceNamed(@src(), "render");
            defer rendering.end();

            // TODO: to reassemble saved frames into better looking video we probably must
            // pipe timing info because fps might not be constant (is even possible?)

            gl.readPixels(
                0,
                0,
                rl.getScreenWidth(),
                rl.getScreenHeight(),
                .rgba,
                .unsigned_byte,
                @ptrCast(pixels.?),
            );

            try r.write(pixels.?);

            if (!x11.x11_thread_active) {
                exit_window = true;
            }
        }
    }

    // NOTE: not able to stop x11Listener yet, applicable only for x11Producer
    x11.run_x11_thread = false;

    if (renderer) |*r| try r.wait();

    std.debug.print("Exit\n", .{});
}

