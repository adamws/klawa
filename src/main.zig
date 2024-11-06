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

const Ffmpeg = @import("ffmpeg.zig").Ffmpeg;
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
    kle,
    vortex_pok3r,

    const keycaps_kle_data = @embedFile("resources/keycaps_kle_with_gaps_atlas.png");
    const keycaps_vortex_pok3r_data = @embedFile("resources/keycaps_vortex_pok3r_atlas.png");

    pub fn getData(self: Theme) []const u8 {
        return switch (self) {
            .kle => keycaps_kle_data,
            .vortex_pok3r => keycaps_vortex_pok3r_data,
        };
    }

    pub fn fromString(value: []const u8) ?Theme {
        return std.meta.stringToEnum(Theme, value);
    }
};

pub const Layout = enum {
    @"60_iso",

    const layout_60_iso_data = @embedFile("resources/keyboard-layout.json");

    pub fn getData(self: Layout) []const u8 {
        return switch (self) {
            .@"60_iso" => layout_60_iso_data,
        };
    }

    pub fn fromString(value: []const u8) ?Layout {
        return std.meta.stringToEnum(Layout, value);
    }
};

const ConfigData = struct {
    typing_font_size: i32 = 120,
    typing_font_color: u32 = 0x000000ff, // alpha=1
    layout_path: []const u8 = "", // absolute or realative to config file
    theme: []const u8 = "kle",
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

const SymbolsLookupKV = struct { []const u8, [:0]const u8 };
// TODO: symbols subsitution should be configurable
const symbols_lookup_slice = [_]SymbolsLookupKV{
    // zig fmt: off
    .{ "Escape",       "Esc"     },
    .{ "Tab",          "↹"       },
    .{ "ISO_Left_Tab", "↹"       },
    .{ "Return",       "⏎"       },
    .{ "space",        "␣"       },
    .{ "BackSpace",    "⌫"       },
    .{ "Caps_Lock",    "Caps"    },
    .{ "F1",           "F1"      },
    .{ "F2",           "F2"      },
    .{ "F3",           "F3"      },
    .{ "F4",           "F4"      },
    .{ "F5",           "F5"      },
    .{ "F6",           "F6"      },
    .{ "F7",           "F7"      },
    .{ "F8",           "F8"      },
    .{ "F9",           "F9"      },
    .{ "F10",          "F10"     },
    .{ "F11",          "F11"     },
    .{ "F12",          "F12"     },
    .{ "Up",           "↑"       },
    .{ "Left",         "←"       },
    .{ "Right",        "→"       },
    .{ "Down",         "↓"       },
    .{ "Prior",        "PgUp"    },
    .{ "Next",         "PgDn"    },
    .{ "Home",         "Home"    },
    .{ "End",          "End"     },
    .{ "Insert",       "Ins"     },
    .{ "Delete",       "Del"     },
    .{ "KP_End",       "1ᴷᴾ"     },
    .{ "KP_Down",      "2ᴷᴾ"     },
    .{ "KP_Next",      "3ᴷᴾ"     },
    .{ "KP_Left",      "4ᴷᴾ"     },
    .{ "KP_Begin",     "5ᴷᴾ"     },
    .{ "KP_Right",     "6ᴷᴾ"     },
    .{ "KP_Home",      "7ᴷᴾ"     },
    .{ "KP_Up",        "8ᴷᴾ"     },
    .{ "KP_Prior",     "9ᴷᴾ"     },
    .{ "KP_Insert",    "0ᴷᴾ"     },
    .{ "KP_Delete",    "(.)"     },
    .{ "KP_Add",       "(+)"     },
    .{ "KP_Subtract",  "(-)"     },
    .{ "KP_Multiply",  "(*)"     },
    .{ "KP_Divide",    "(/)"     },
    .{ "KP_Enter",     "⏎"       },
    .{ "KP_1",         "1ᴷᴾ"     },
    .{ "KP_2",         "2ᴷᴾ"     },
    .{ "KP_3",         "3ᴷᴾ"     },
    .{ "KP_4",         "4ᴷᴾ"     },
    .{ "KP_5",         "5ᴷᴾ"     },
    .{ "KP_6",         "6ᴷᴾ"     },
    .{ "KP_7",         "7ᴷᴾ"     },
    .{ "KP_8",         "8ᴷᴾ"     },
    .{ "KP_9",         "9ᴷᴾ"     },
    .{ "KP_0",         "0ᴷᴾ"     },
    .{ "Num_Lock",     "NumLck"  },
    .{ "Scroll_Lock",  "ScrLck"  },
    .{ "Pause",        "Pause"   },
    .{ "Break",        "Break"   },
    .{ "Print",        "Print"   },
    .{ "Multi_key",    "Compose" },
    // zig fmt: on
};
const symbols_lookup = std.StaticStringMap([:0]const u8).initComptime(symbols_lookup_slice);
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
                s.src.y = 1728;
                s.dst.x -= 0.25 * KEY_1U_PX;
            } else if (k.width == 1.0 and k.height == 2.0) {
                s.src.x = 0;
                s.src.y = 1728 - 64;
            }

            s.pressed = false;
        }
    }

    fn calculateKeyLookup(self: *AppState) !void {
        for (self.keyboard.keys, 0..) |key, index| {
            const label = key.labels[0];
            if (label) |l| {
                var iter = std.mem.split(u8, l, ",");
                while (iter.next()) |part| {
                    const integer = try std.fmt.parseInt(u8, part, 10);
                    self.keycode_keyboard_lookup[@as(usize, integer)] = @intCast(index);
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
            .layout = @embedFile("resources/keyboard-layout.json"),
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

    const executable_dir = try known_folders.getPath(allocator, .executable_dir) orelse unreachable;
    defer allocator.free(executable_dir);
    std.debug.print("executable_dir {s}\n", .{executable_dir});

    // config parse:
    // TODO: for now look for config file only in executable dir, later should use XDG rules
    const config_dir = executable_dir;
    // use '\0' terminated alloc because this will be passed to inotify syscalls (in c)
    const config_path = try std.fmt.allocPrintZ(allocator, "{s}/config", .{config_dir});
    defer allocator.free(config_path);

    var app_config = config.configManager(ConfigData, allocator);
    defer app_config.deinit();

    _ = app_config.loadFromFile(config_path) catch |err| switch (err) {
        error.ConfigNotFound => std.debug.print("Default builtin config\n", .{}),
        else => return err,
    };

    const typing_font_size = app_config.data.typing_font_size;
    const typing_font_color: rl.Color = rl.Color.fromInt(app_config.data.typing_font_color);
    const layout_path = app_config.data.layout_path;
    const theme_name = app_config.data.theme;

    var config_watch = try config.Watch.init(config_path);
    defer config_watch.deinit();

    app_state = try getState(allocator, config_dir, layout_path, Layout.@"60_iso");
    defer app_state.deinit();

    // window creation

    rl.setConfigFlags(.{ .msaa_4x_hint = true, .vsync_hint = true, .window_highdpi = true });
    rl.initWindow(app_state.window_width, app_state.window_height, "klawa");
    defer rl.closeWindow();

    // TODO: make this optional/configurable:
    rl.setWindowState(.{ .window_undecorated = true });
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

    const theme = Theme.fromString(theme_name) orelse unreachable;
    const keycaps = theme.getData();
    const keycaps_image = rl.loadImageFromMemory(".png", keycaps);
    const keycap_texture = rl.loadTextureFromImage(keycaps_image);
    defer rl.unloadTexture(keycap_texture);

    rl.setTextureFilter(keycap_texture, rl.TextureFilter.texture_filter_bilinear);

    // texture created, image no longer needed
    rl.unloadImage(keycaps_image);

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
                .layout_path => {
                    std.debug.print("Reload layout from '{s}'\n", .{app_config.data.layout_path});
                    if (getState(allocator, config_dir, app_config.data.layout_path, Layout.@"60_iso")) |new_state| {
                        app_state.deinit();
                        app_state = new_state;
                        rl.setWindowSize(app_state.window_width, app_state.window_height);
                    } else |err| switch (err) {
                        else => unreachable,
                    }
                },
                .theme => std.debug.print("should reload theme to '{s}' (not supported yet)\n", .{app_config.data.theme}),
                else => {},
            };
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
            // TODO: tint color should be configurable
            const tint = if (k.pressed) rl.Color.red else rl.Color.white;
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

        if (show_gui) {
            rl.drawRectangle(
                0,
                0,
                app_state.window_width,
                app_state.window_height,
                rl.Color{ .r = 255, .g = 255, .b = 255, .a = 196 },
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

