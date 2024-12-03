const clap = @import("clap");
const rl = @import("raylib");
const rgui = @import("raygui");
const std = @import("std");
const fs = std.fs;
const known_folders = @import("known-folders");
const KnownFolder = known_folders.KnownFolder;

const builtin = @import("builtin");

const config = @import("config.zig");
const kle = @import("kle.zig");
const math = @import("math.zig");
const textures = @import("textures.zig");
const tracy = @import("tracy.zig");

const backend = switch (builtin.target.os.tag) {
    .linux => @import("x11.zig"),
    .windows => @import("win32.zig"),
    else => @compileError("unsupported platform"),
};

const labels_lookup = @import("layout_labels.zig").labels_lookup;
const symbols_lookup = @import("symbols_lookup.zig").symbols_lookup;

const CountingStringRingBuffer = @import("strings.zig").CountingStringRingBuffer;
const Ffmpeg = @import("ffmpeg.zig").Ffmpeg;
const Layout = @import("layout.zig").Layout;
const SpscQueue = @import("spsc_queue.zig").SpscQueue;
const Watch = @import("watch.zig").Watch;

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
    custom, // special theme which uses user provided image as atlas
    custom_from_keycap, // special theme which uses user provided image to generate atlas

    const keycaps_default_data = @embedFile("resources/keycaps_default_atlas.png");
    const keycaps_kle_data = @embedFile("resources/keycaps_kle_with_gaps_atlas.png");
    const keycaps_vortex_pok3r_data = @embedFile("resources/keycaps_vortex_pok3r_atlas.png");

    pub fn getData(self: Theme) ?[]const u8 {
        return switch (self) {
            .default => keycaps_default_data,
            .kle => keycaps_kle_data,
            .vortex_pok3r => keycaps_vortex_pok3r_data,
            .custom, .custom_from_keycap => null,
        };
    }

    pub fn fromString(value: []const u8) ?Theme {
        return std.meta.stringToEnum(Theme, value);
    }
};

pub const KeyPressEffect = enum {
    none,
    move,
    squash,

    pub fn fromString(value: []const u8) ?KeyPressEffect {
        return std.meta.stringToEnum(KeyPressEffect, value);
    }
};

pub const BackspaceMode = enum {
    normal, // always insert backspace symbol
    full,

    pub fn fromString(value: []const u8) ?BackspaceMode {
        return std.meta.stringToEnum(BackspaceMode, value);
    }
};

const ConfigData = struct {
    window_undecorated: bool = true,
    window_transparent: bool = false,
    window_topmost: bool = true,
    window_mouse_passthrough: bool = false, // warning: can't use close or move with mouse, must kill to exit
    window_position_x: i32 = -1,
    window_position_y: i32 = -1,
    draw_fps: bool = false,
    background_color: u32 = 0x000000ff,
    typing_font_size: i32 = 120,
    typing_font_color: u32 = 0x000000ff, // alpha=1
    typing_background_color: u32 = 0x00000080,
    layout_preset: []const u8 = "tkl_ansi",
    layout_path: []const u8 = "", // absolute or realative to config file
    theme: []const u8 = "default",
    theme_custom_atlas_path: []const u8 = "",
    theme_custom_atlas_map: []const u8 = "",
    theme_custom_keycap_path: []const u8 = "",
    show_typing: bool = true,
    show_keyboard: bool = true,
    key_scale: f32 = 1.0,
    key_tint_color: u32 = 0xff0000ff, // alpha=1
    key_press_effect: []const u8 = "move",
    backspace_mode: []const u8 = "normal",
};

const KeyOnScreen = struct {
    src: rl.Rectangle,
    dst: rl.Rectangle,
    angle: f32,
    pressed: bool,
};

pub const KeyData = extern struct {
    pressed: bool,
    keycode: u8,
    keysym: c_ulong,
    string: [32]u8,

    comptime {
        // this type is is copied a lot, keep it small
        std.debug.assert(@sizeOf(KeyData) <= 64);
    }
};

const TypingDisplay = struct {
    string_buffer: CountingStringRingBuffer(capacity, max_string_len) = .{},

    const capacity = 256; // size of key representations history
    const max_string_len = 32; // maximal length of string representation of key (or key combo)
    const repeat_indicator_threshold = 3;
    const max_repeat = std.math.maxInt(usize);
    const max_repeat_indicator = std.fmt.comptimePrint("…{}×", .{max_repeat});

    pub fn update(self: *TypingDisplay, key: KeyData, backspace_mode: BackspaceMode) void {
        const symbol = keySymbol(key);
        if (symbol == null) return;

        std.debug.print("Symbol: {s}\n", .{symbol.?});

        if (key.pressed == false) return;

        if (backspace_mode == .full and std.mem.eql(u8, symbol.?, "BackSpace")) {
            self.string_buffer.backspace();
        } else {
            self.push(key, symbol.?);
        }
    }

    fn push(self: *TypingDisplay, key: KeyData, key_symbol: [:0]const u8) void {
        var text_: [*:0]const u8 = undefined;

        if (symbols_lookup.get(key_symbol)) |lookup| {
            std.debug.print("Replacement: '{s}'\n", .{lookup});
            text_ = lookup;
        } else {
            text_ = @ptrCast(&key.string);
        }
        self.string_buffer.push(std.mem.sliceTo(text_, 0)) catch unreachable;
    }

    fn keySymbol(key: KeyData) ?[:0]const u8 {
        if (backend.keysymToString(key.keysym)) |symbol| {
            return std.mem.sliceTo(symbol, 0);
        }
        return null;
    }

    pub fn render(self: *TypingDisplay, font: rl.Font, position: rl.Vector2, font_size: f32, tint: rl.Color) void {
        var codepoints: [max_string_len]u21 = undefined;
        var num_codepoints: usize = 0;

        const index_of_w: usize = @intCast(rl.getGlyphIndex(font, 'w'));
        const wide_glyph_width = 2 * font.recs[index_of_w].width;

        var offset: f32 = 0;
        var it = self.string_buffer.reverse_iterator();

        while (it.next()) |repeated_string| {
            // to avoid iterating over characters which won't fit in screen anyway
            if (position.x - offset + wide_glyph_width < 0) break;

            var repeat = repeated_string.repeat;
            if (repeat > repeat_indicator_threshold)
            {
                var buf: [max_repeat_indicator.len]u8 = undefined;
                const res = std.fmt.bufPrintZ(&buf, "…{}×", .{repeat}) catch max_repeat_indicator;

                num_codepoints = get_codepoints(res, &codepoints);
                render_codepoints(font, position, font_size, tint, codepoints[0..num_codepoints], &offset);

                repeat = repeat_indicator_threshold;
            }

            num_codepoints = get_codepoints(repeated_string.string, &codepoints);
            for (0..repeat) |_| {
                render_codepoints(font, position, font_size, tint, codepoints[0..num_codepoints], &offset);
            }
        }
    }

    fn get_codepoints(string: []const u8, output: []u21) usize {
        var utf8 = std.unicode.Utf8View.initUnchecked(string).iterator();
        var i: usize = 0;
        while (utf8.nextCodepoint()) |cp| {
            if (i >= output.len) break;
            output[i] = cp;
            i += 1;
        }
        return i;
    }

    fn render_codepoints(font: rl.Font, position: rl.Vector2, font_size: f32, tint: rl.Color, codepoints: []u21, offset: *f32) void {
        const scale_factor: f32 = font_size / @as(f32, @floatFromInt(font.baseSize));

        var i: usize = codepoints.len;
        while (i > 0) {
            i -= 1;
            const cp: i32 = @intCast(codepoints[i]);
            const glyph_index: usize = @intCast(rl.getGlyphIndex(font, cp));
            const glyph_position = rl.Vector2.init(
                position.x - offset.*,
                position.y,
            );
            rl.drawTextCodepoint(font, cp, glyph_position, font_size, tint);

            offset.* += switch (font.glyphs[glyph_index].advanceX) {
                0 => font.recs[glyph_index].width * scale_factor,
                else => @as(f32, @floatFromInt(font.glyphs[glyph_index].advanceX)) * scale_factor,
            };
        }
    }
};

const KeyDataProducer = struct {
    reader: std.io.AnyReader,
    frame_read: bool,
    next_frame: usize = 0,

    pub fn init(reader: std.io.AnyReader) KeyDataProducer {
        return .{
            .reader = reader,
            .frame_read = true,
        };
    }

    fn nextFrame(self: *KeyDataProducer) !usize {
        if (self.frame_read) {
            self.next_frame = try self.reader.readInt(usize, .little);
            self.frame_read = false;
        }
        return self.next_frame;
    }

    fn next(self: *KeyDataProducer) !KeyData {
        const key_data = try self.reader.readStruct(KeyData);
        self.frame_read = true;
        return key_data;
    }

    pub fn getDataForFrame(self: *KeyDataProducer, frame: usize) !?KeyData {
        const next_frame = try self.nextFrame();
        if (next_frame == frame) {
            return try self.next();
        }
        return null;
    }
};

fn getDataForFrame(frame: usize) !?KeyData {
    if (key_data_producer) |*producer| {
        return try producer.getDataForFrame(frame);
    }
    return null;
}

var key_data_producer: ?KeyDataProducer = null;
pub var app_state: AppState = undefined;

// https://github.com/bits/UTF-8-Unicode-Test-Documents/blob/master/UTF-8_sequence_unseparated/utf8_sequence_0-0xfff_assigned_printable_unseparated.txt
const text = @embedFile("resources/utf8_sequence_0-0xfff_assigned_printable_unseparated.txt");

const symbols = "↚↹⏎␣⌫↑←→↓ᴷᴾ⏎…×";
const all_text = text ++ symbols;

// it contains all current sumstitutions symbols:
// TODO: font discovery with fallbacks when glyph not found
// TODO: support for non-monospaced fonts
const font_data = @embedFile("resources/DejaVuSansMono.ttf");

pub const AppState = struct {
    key_states: [MAX_KEYS]KeyOnScreen,
    keycode_keyboard_lookup: [256]i32,
    window_width: c_int,
    window_height: c_int,
    show_typing: bool,
    show_keyboard: bool,
    key_scale: f32,
    key_press_effect: KeyPressEffect,
    key_pressed_travel: f32,
    background_color: rl.Color,
    typing_font_size: i32,
    typing_font_color: rl.Color,
    typing_background_color: rl.Color,
    key_tint_color: rl.Color,
    backspace_mode: BackspaceMode,
    keys: Queue = Queue.init(),
    last_char_timestamp: i64 = 0,

    const MAX_KEYS = 512;
    const Queue = SpscQueue(32, KeyData);
    const KEY_1U_PX = 64;

    pub fn init(keys: []kle.Key, config_data: ConfigData) !AppState {
        if (keys.len > MAX_KEYS) return error.TooManyKeys;

        var self: AppState = .{
            .key_states = undefined,
            .keycode_keyboard_lookup = .{-1} ** 256,
            .window_width = -1,
            .window_height = -1,
            .show_typing = config_data.show_typing,
            .show_keyboard = config_data.show_keyboard,
            .key_scale = config_data.key_scale,
            .key_press_effect = KeyPressEffect.fromString(config_data.key_press_effect) orelse KeyPressEffect.move,
            .key_pressed_travel = @divTrunc(KEY_1U_PX, 10) * config_data.key_scale,
            .background_color = rl.Color.fromInt(config_data.background_color),
            .typing_font_size = config_data.typing_font_size,
            .typing_font_color = rl.Color.fromInt(config_data.typing_font_color),
            .typing_background_color = rl.Color.fromInt(config_data.typing_background_color),
            .key_tint_color = rl.Color.fromInt(config_data.key_tint_color),
            .backspace_mode = BackspaceMode.fromString(config_data.backspace_mode) orelse BackspaceMode.normal,
        };

        calcualteWindoWize(&self, keys);
        try initKeys(&self, keys, config_data.theme_custom_atlas_map);
        try calculateKeyLookup(&self, keys);
        return self;
    }

    pub fn updateColor(self: *AppState, comptime name: []const u8, config_data: ConfigData) void {
        @field(self, name) = rl.Color.fromInt(@field(config_data, name));
    }

    fn initKeys(self: *AppState, keys: []kle.Key, atlas_map: []const u8) !void {
        var atlas_map_parsed: [MAX_KEYS]rl.Vector2 = undefined;
        if (atlas_map.len != 0) {
            try convertAtlasMap(atlas_map, &atlas_map_parsed);
        }

        for (keys, 0..) |k, index| {
            var s = &self.key_states[index];
            s.pressed = false;

            s.dst = getKeyDestination(&k);
            s.angle = @floatCast(k.rotation_angle);

            if (atlas_map.len != 0) {
                s.src.x = atlas_map_parsed[index].x;
                s.src.y = atlas_map_parsed[index].y;
                s.src.width = s.dst.width;
                s.src.height = s.dst.height;
            } else {
                s.src = getKeySource(rl.Vector2{.x = s.dst.width, .y = s.dst.height});
            }

            s.dst.x *= self.key_scale;
            s.dst.y *= self.key_scale;
            s.dst.width *= self.key_scale;
            s.dst.height *= self.key_scale;
        }
    }

    fn getKeyDestination(k: *const kle.Key) rl.Rectangle {
        const angle_rad = std.math.rad_per_deg * k.rotation_angle;
        const point = math.Vec2{ .x = k.x, .y = k.y };
        const rot_origin = math.Vec2{ .x = k.rotation_x, .y = k.rotation_y };
        const result = math.rotate_around_center(point, rot_origin, angle_rad);

        const width: f32 = @floatCast(KEY_1U_PX * @max(k.width, k.width2));
        const height: f32 = @floatCast(KEY_1U_PX * @max(k.height, k.height2));

        // iso enter, might not work when rotated. For now only non-rectangular supported key
        var x_offset: f32 = 0;
        if (k.width == 1.25 and k.width2 == 1.5 and k.height == 2 and k.height2 == 1) {
            x_offset = -0.25 * KEY_1U_PX;
        }

        return .{
            .x = @as(f32, @floatCast(KEY_1U_PX * result.x)) + x_offset,
            .y = @as(f32, @floatCast(KEY_1U_PX * result.y)),
            .width = width,
            .height = height,
        };
    }

    fn getKeySource(size: rl.Vector2) rl.Rectangle {
        const position = textures.getPositionBySize(size);
        return .{
            .x = position.x,
            .y = position.y,
            .width = size.x,
            .height = size.y,
        };
    }

    fn convertAtlasMap(atlas_map: []const u8, atlas_map_parsed: []rl.Vector2) !void {
        var iter = std.mem.split(u8, atlas_map, ",");
        var i: usize = 0;
        while (iter.next()) |map| {
            if (i >= atlas_map_parsed.len) return error.TooManyEntriesInAtlasMap;

            std.debug.print("{} {s}\n", .{i, map});

            var number_parsed: [2]usize = undefined;
            var number_iter = std.mem.split(u8, map, " ");
            var j: usize = 0;
            while (number_iter.next()) |number| {
                if (number.len == 0) continue;
                number_parsed[j] = try std.fmt.parseInt(usize, number, 0);
                j += 1;
            }

            atlas_map_parsed[i].x = @floatFromInt(number_parsed[0]);
            atlas_map_parsed[i].y = @floatFromInt(number_parsed[1]);
            i += 1;
        }
    }

    fn calculateKeyLookup(self: *AppState, keys: []kle.Key) !void {
        var universal_key_label: [128]u8 = undefined;
        for (keys, 0..) |key, index| {
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

    fn calcualteWindoWize(self: *AppState, keys: []kle.Key) void {
        const bbox = calculateBoundingBox(keys);
        self.window_width = @intFromFloat(bbox.w * KEY_1U_PX * self.key_scale);
        self.window_height = @intFromFloat(bbox.h * KEY_1U_PX * self.key_scale);
        if (!self.show_keyboard) {
            self.window_height = self.typing_font_size;
        }
        std.debug.print("Window size: {}x{}\n", .{ self.window_width, self.window_height });
    }

    fn calculateBoundingBox(keys: []kle.Key) struct { x: f64, y: f64, w: f64, h: f64 } {
        var max_x: f64 = 0;
        var max_y: f64 = 0;
        for (keys) |k| {
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
};

fn getKleStr(allocator: std.mem.Allocator, config_path: []const u8, config_data: ConfigData) ![]const u8 {
    if (config_data.layout_path.len != 0) {
        std.debug.print("Load layout using file '{s}'\n", .{config_data.layout_path});
        var dir = try fs.cwd().openDir(config_path, .{});
        defer dir.close();
        var layout_file = try dir.openFile(config_data.layout_path, .{});
        return try layout_file.readToEndAlloc(allocator, 4096);
    }

    const layout = Layout.fromString(config_data.layout_preset) orelse Layout.tkl_ansi;
    std.debug.print("Load layout using preset '{s}'\n", .{@tagName(layout)});
    return try allocator.dupe(u8, layout.getData());
}

fn getState(allocator: std.mem.Allocator, config_path: []const u8, config_data: ConfigData) !AppState {
    const kle_str: []const u8 = try getKleStr(allocator, config_path, config_data);
    defer allocator.free(kle_str);

    const parsed = try kle.parseFromSlice(allocator, kle_str);
    defer parsed.deinit();

    return AppState.init(parsed.value.keys, config_data);
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
        defer parsed.deinit();

        const default_config: ConfigData = .{};
        const s = try AppState.init(parsed.value.keys, default_config);

        try std.testing.expect(s.window_width == case.expected.w);
        try std.testing.expect(s.window_height == case.expected.h);
    }
}

fn loadTexture(theme: Theme, atlas_path: [:0]const u8, keycap_path: [:0]const u8) rl.Texture {
    const keycaps_image = blk: {
        if (theme == .custom_from_keycap) {
            const image = textures.generate_texture_atlas_image(keycap_path) catch unreachable;
            break :blk image;
        }

        if (theme.getData()) |keycaps| {
            break :blk rl.loadImageFromMemory(".png", keycaps);
        } else {
            break :blk rl.loadImage(atlas_path);
        }
    };
    const keycap_texture = rl.loadTextureFromImage(keycaps_image);
    rl.setTextureFilter(keycap_texture, rl.TextureFilter.texture_filter_bilinear);
    // texture created, image no longer needed
    rl.unloadImage(keycaps_image);

    return keycap_texture;
}

fn updateWindowFlag(comptime flag_name: []const u8, value: bool) void {
    var flags = std.mem.zeroInit(rl.ConfigFlags, .{});
    @field(flags, flag_name) = true;
    if (value) {
        rl.setWindowState(flags);
    } else {
        rl.clearWindowState(flags);
    }
}

fn updateWindowPos(x: i32, y: i32) void {
    if (x != -1 and y != -1) {
        rl.setWindowPosition(x, y);
    }
}

var exit_window = false;

fn sigtermHandler(sig: c_int) callconv(.C) void {
    _ = sig;
    exit_window = true;
}

fn sigtermInstall() !void {
    const act = std.os.linux.Sigaction{
        .handler = .{ .handler = sigtermHandler },
        .mask = std.os.linux.empty_sigset,
        .flags = 0,
    };

    if (std.os.linux.sigaction(std.os.linux.SIG.TERM, &act, null) != 0) {
        return error.SignalHandlerError;
    }
}

pub fn main() !void {
    const trace_ = tracy.trace(@src());
    defer trace_.end();

    try sigtermInstall();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cwd = fs.cwd();

    const params = comptime clap.parseParamsComptime(
        \\    --record <str>       Record events to file.
        \\    --replay <str>       Replay events from file.
        \\    --replay-loop        Loop replay action. When not set app will exit after replay ends.
        \\    --render <str>       Render frames to video file. Works only with replay without loop.
        \\    --save-atlas <str>   Saves current keyboard to atlas file in current working directory.
        \\    --keycap <str>       Path to keycap theme. (temporary for development)
        \\    --output <str>       Path to result atlas file. (temporary for development)
        \\-h, --help               Display this help and exit.
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

    // check if updating builtin texture atlases

    if (res.args.keycap) |keycap_file| {
        const keycap_file_path = try allocator.dupeZ(u8, keycap_file);
        defer allocator.free(keycap_file_path);

        const output_file_path = try allocator.dupeZ(u8, res.args.output.?);
        defer allocator.free(output_file_path);

        try textures.generate_texture_atlas(keycap_file_path, output_file_path);
        return;
    }

    // config handling

    const config_path = blk: {

        if (builtin.os.tag == .windows) {
            // check if inside wine, known_folders crashes on wine (did not debug it yet)
            const kernel32 = std.os.windows.kernel32;
            const ntdll = kernel32.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("ntdll.dll"));
            const pwine = kernel32.GetProcAddress(ntdll.?, "wine_get_version");
            if (@intFromPtr(pwine) != 0) {
                std.debug.print("Running inside wine\n", .{});
                break :blk try std.fmt.allocPrintZ(allocator, "config", .{});
            }
        }

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

    var config_watch = try Watch.init(config_path);
    defer config_watch.deinit();

    app_state = try getState(allocator, config_dir, app_config.data);

    // window creation

    rl.setConfigFlags(.{
        // experimentation shown that window transparency does not work when msaa_4x_hint enabled
        // (at least on my linux machine with compton composition manager)
        .msaa_4x_hint = if (app_config.data.window_transparent) false else true,
        .vsync_hint = true,
        .window_highdpi = true,
        .window_transparent = app_config.data.window_transparent,
        .window_topmost = app_config.data.window_topmost,
        .window_mouse_passthrough = app_config.data.window_mouse_passthrough,
    });
    rl.initWindow(app_state.window_width, app_state.window_height, "klawa");
    defer rl.closeWindow();

    updateWindowPos(app_config.data.window_position_x, app_config.data.window_position_y);

    rl.setWindowState(.{ .window_undecorated = app_config.data.window_undecorated });
    rl.setExitKey(rl.KeyboardKey.key_null);

    const window_handle = rl.getWindowHandle();

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

    if (res.args.replay) |replay_file| {
        const file = try fs.cwd().openFile(replay_file, .{});
        //defer file.close();
        var buf_reader = std.io.bufferedReader(file.reader());
        const reader = buf_reader.reader();
        key_data_producer = KeyDataProducer.init(reader.any());
    }

    const replay: bool = res.args.replay != null;
    const listener = switch(replay) {
       false => try std.Thread.spawn(.{}, backend.listener, .{ &app_state, window_handle }),
       true => null,
    };
    defer {
        if (listener) |l| {
            backend.stop();
            l.join();
        }
    }

    var keycap_texture = blk: {
        const theme = Theme.fromString(app_config.data.theme) orelse unreachable;
        const atlas_path = try allocator.dupeZ(u8, app_config.data.theme_custom_atlas_path);
        defer allocator.free(atlas_path);
        const keycap_path = try allocator.dupeZ(u8, app_config.data.theme_custom_keycap_path);
        defer allocator.free(keycap_path);
        // TODO: maybe just pass config?
        break :blk loadTexture(theme, atlas_path, keycap_path);
    };
    defer rl.unloadTexture(keycap_texture);

    if (res.args.@"save-atlas") |atlas_file| {
        const target = rl.loadRenderTexture(app_state.window_width, app_state.window_height);
        defer rl.unloadRenderTexture(target);

        rl.beginTextureMode(target);

        const rot = rl.Vector2{ .x = 0, .y = 0 };
        std.debug.print("This is mapping for currently generated atlas, copy this to config\n", .{});
        for (app_state.key_states) |k| {
            rl.drawTexturePro(keycap_texture, k.src, k.dst, rot, k.angle, rl.Color.white);
            std.debug.print("{d: >5} {d: >5},\n", .{k.dst.x, k.dst.y});
        }

        rl.endTextureMode();

        var image = rl.loadImageFromTexture(target.texture);
        defer rl.unloadImage(image);

        rl.imageFlipVertical(&image);

        const atlas_file_z = try allocator.dupeZ(u8, atlas_file);
        defer allocator.free(atlas_file_z);
        _ = rl.exportImage(image, atlas_file_z);
        return;
    }

    // TODO: implement font discovery
    // TODO: if not found fallback to default
    const codepoints = try rl.loadCodepoints(all_text);
    defer rl.unloadCodepoints(codepoints);

    std.debug.print("Text contains {} codepoints\n", .{codepoints.len});

    // TODO: font should be configurable
    var font = rl.loadFontFromMemory(".ttf", font_data, app_state.typing_font_size, codepoints);
    defer rl.unloadFont(font);

    var show_gui = false;

    const typing_persistance_sec = 2;

    var typing_display = TypingDisplay{};

    var drag_reference_position = rl.getWindowPosition();

    // TODO: use buffered writer, to do that we must gracefully handle this thread exit,
    // otherwise there is no good place to ensure writer flush
    // TODO: support full file path
    var event_file: ?fs.File = null;
    if (res.args.record) |record_file| {
        event_file = try cwd.createFile(record_file, .{});
    }
    defer if(event_file) |value| value.close();

    var frame: usize = 0;

    while (!exit_window) {
        if (rl.windowShouldClose()) {
            exit_window = true;
        }

        if (rl.isMouseButtonPressed(rl.MouseButton.mouse_button_middle)) {
            std.debug.print("Toggle settings\n", .{});
            show_gui = !show_gui;
        }

        if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_right)) {
            if (rl.isMouseButtonPressed(rl.MouseButton.mouse_button_right)) {
                drag_reference_position = rl.getMousePosition();
                rl.setMouseCursor(rl.MouseCursor.mouse_cursor_resize_all);
            }

            const current_position: rl.Vector2 = blk: {
                const p = try backend.getMousePosition();
                break :blk .{
                    .x = @floatFromInt(p.x),
                    .y = @floatFromInt(p.y),
                };
            };
            const win_pos = current_position.subtract(drag_reference_position);
            rl.setWindowPosition(@intFromFloat(@round(win_pos.x)), @intFromFloat(@round(win_pos.y)));
        }

        if (rl.isMouseButtonReleased(rl.MouseButton.mouse_button_right)) {
            rl.setMouseCursor(rl.MouseCursor.mouse_cursor_arrow);
        }

        // TODO: handle errors
        if (try config_watch.checkForChanges()) {
            std.debug.print("Config file change detected\n", .{});
            const changes = try app_config.loadFromFile(config_path);
            var iter = changes.iterator();
            while (iter.next()) |v| switch(v) {
                inline .window_undecorated, .window_transparent, .window_topmost, .window_mouse_passthrough => |flag| {
                    updateWindowFlag(@tagName(flag), @field(app_config.data, @tagName(flag)));
                },
                .window_position_x, .window_position_y => {
                    updateWindowPos(app_config.data.window_position_x, app_config.data.window_position_y);
                },
                .layout_path, .layout_preset, .key_scale, .show_keyboard => {
                    if (getState(allocator, config_dir, app_config.data)) |new_state| {
                        app_state = new_state;
                        rl.setWindowSize(app_state.window_width, app_state.window_height);
                        // TODO: update window position when layout changed, probably should add
                        // config option which will define reference points (corners + middle)
                        //updateWindowPos(app_config.data.window_position_x, app_config.data.window_position_y);
                    } else |err| switch (err) {
                        error.FileNotFound => std.debug.print("Layout file not found, reload aborted\n", .{}),
                        else => unreachable,
                    }
                },
                .theme, .theme_custom_atlas_path => {
                    std.debug.print("Reload theme to '{s}'\n", .{app_config.data.theme});
                    if (Theme.fromString(app_config.data.theme)) |new_theme| {
                        keycap_texture = blk: {
                            rl.unloadTexture(keycap_texture);
                            const atlas_path = try allocator.dupeZ(u8, app_config.data.theme_custom_atlas_path);
                            defer allocator.free(atlas_path);
                            const keycap_path = try allocator.dupeZ(u8, app_config.data.theme_custom_keycap_path);
                            defer allocator.free(keycap_path);
                            break :blk loadTexture(new_theme, atlas_path, keycap_path);
                        };
                    } else {
                        std.debug.print("Got unrecognized theme: '{s}', reload aborted\n", .{app_config.data.theme});
                    }
                },
                .typing_font_size => {
                    rl.unloadFont(font);
                    // TODO: sanitize, sizes <0 and larger than window height probably should be skipped
                    font = rl.loadFontFromMemory(".ttf", font_data, app_config.data.typing_font_size, codepoints);
                    app_state.typing_font_size = app_config.data.typing_font_size;
                },
                inline .background_color, .typing_font_color, .typing_background_color, .key_tint_color => |color| {
                    app_state.updateColor(@tagName(color), app_config.data);
                },
                inline .show_typing => |value| {
                    const name = @tagName(value);
                    @field(app_state, name) = @field(app_config.data, name);
                },
                .key_press_effect => {
                    if (KeyPressEffect.fromString(app_config.data.key_press_effect)) |value| {
                        app_state.key_press_effect = value;
                    } else {
                        app_state.key_press_effect = KeyPressEffect.move;
                    }
                },
                .backspace_mode => {
                    if (BackspaceMode.fromString(app_config.data.backspace_mode)) |value| {
                        app_state.backspace_mode = value;
                    } else {
                        app_state.backspace_mode = BackspaceMode.normal;
                    }
                },
                else => {},
            };
        }

        // replay
        if (getDataForFrame(frame)) |data| {
            if (data) |value| {
                if (value.string[0] != 0) {
                    // update only for keys which produce output,
                    // this will not include modifiers
                    app_state.last_char_timestamp = std.time.timestamp();
                }
                std.debug.print("Push {any}\n", .{value});
                _ = app_state.keys.push(value);
            }
        } else |err| switch (err) {
            error.EndOfStream => {
                std.debug.print("END OF STREAM\n", .{});
                exit_window = true;
            },
            else => return err,
        }

        if (app_state.keys.pop()) |k| {
            // save state (if recording)
            if (event_file) |value| {
                _ = try value.writeAll(std.mem.asBytes(&frame));
                // TODO:
                // writing full k struct is very wasteful, there is a lot of non-essential
                // data (for example each release event writes 32 bytes of empty string),
                // do not worry about that now, optimize for space later.
                _ = try value.writeAll(std.mem.asBytes(&k));
            }

            app_state.updateKeyStates(@intCast(k.keycode), k.pressed);
            typing_display.update(k, app_state.backspace_mode);
        }

        rl.beginDrawing();
        rl.clearBackground(app_state.background_color);

        const rot = rl.Vector2{ .x = 0, .y = 0 };

        if (app_state.show_keyboard) {
            for (app_state.key_states) |k| {
                var dst = k.dst;
                if (k.pressed) switch(app_state.key_press_effect) {
                    .move => dst.y += app_state.key_pressed_travel,
                    .squash => {
                        dst.height -= app_state.key_pressed_travel;
                        dst.y += app_state.key_pressed_travel;
                    },
                    else => {},
                };
                const tint = if (k.pressed) app_state.key_tint_color else rl.Color.white;
                rl.drawTexturePro(keycap_texture, k.src, dst, rot, k.angle, tint);
            }
        }

        if (app_state.show_typing and
            std.time.timestamp() - app_state.last_char_timestamp <= typing_persistance_sec) {

            const typing_x_pos: f32 = @floatFromInt(@divTrunc(app_state.window_width, 2));
            const typing_y_pos: f32 = @floatFromInt(@divTrunc(app_state.window_height - app_state.typing_font_size, 2));
            rl.drawRectangle(
                0,
                @intFromFloat(typing_y_pos),
                app_state.window_width,
                app_state.typing_font_size,
                app_state.typing_background_color,
            );

            typing_display.render(font, rl.Vector2.init(typing_x_pos, typing_y_pos), @floatFromInt(app_state.typing_font_size), app_state.typing_font_color);
        }

        // button for closing application when window decorations disabled,
        // toggled with mouse middle click
        if (show_gui) {
            const status_bar_rect = rl.Rectangle.init(0, 0, @floatFromInt(app_state.window_width), 24);
            const button_rect = rl.Rectangle.init(status_bar_rect.width - 24, 3, 18, 18);

            rgui.guiSetStyle(.statusbar, @intFromEnum(rgui.GuiControlProperty.text_alignment), @intFromEnum(rgui.GuiTextAlignment.text_align_right));
            _ = rgui.guiStatusBar(status_bar_rect, "Exit");
            if (1 == rgui.guiButton(button_rect, "#113#")) {
                exit_window = true;
            }
        }

        if (app_config.data.draw_fps) {
            rl.drawFPS(10, 10);
        }
        rl.endDrawing();
        tracy.frameMark();
        frame += 1;

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
        }
    }

    if (renderer) |*r| try r.wait();

    std.debug.print("Main thread exit\n", .{});
}

