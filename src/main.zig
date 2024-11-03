const clap = @import("clap");
const rl = @import("raylib");
const rgui = @import("raygui");
const std = @import("std");
const fs = std.fs;
const tracy = @import("tracy.zig");
const known_folders = @import("known-folders");
const KnownFolder = known_folders.KnownFolder;

const x11 = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/extensions/XInput2.h");
});

const builtin = @import("builtin");
const debug = (builtin.mode == std.builtin.OptimizeMode.Debug);

const config = @import("config.zig");
const math = @import("math.zig");
const kle = @import("kle.zig");

const Ffmpeg = @import("ffmpeg.zig").Ffmpeg;
const SpscQueue = @import("spsc_queue.zig").SpscQueue;

const glfw = struct {
    pub const GLFWwindow = opaque {};
    // these should be exported in libraylib.a:
    pub extern "c" fn glfwGetX11Window(window: ?*GLFWwindow) x11.Window;
    pub const getX11Window = glfwGetX11Window;
};

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

const KEY_1U_PX = 64;

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
        std.debug.print("Theme: '{s}'\n", .{value});
        return std.meta.stringToEnum(Theme, value);
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

const KeyData = struct {
    pressed: bool,
    repeated: bool,
    keycode: x11.KeyCode,
    keysym: x11.KeySym,
    status: x11.Status,
    symbol: [*c]u8, // owned by x11, in static area. Must not be modified.
    string: [32]u8,

    comptime {
        // this type is is copied a lot, keep it small
        std.debug.assert(@sizeOf(KeyData) <= 64);
    }
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

const X11InputContext = struct {
    display: *x11.Display,
    xim: x11.XIM,
    xic: x11.XIC,

    pub fn init(display: *x11.Display, window: x11.Window) !X11InputContext {
        const xim = x11.XOpenIM(display, null, null, null) orelse {
            std.debug.print("Cannot initialize input method\n", .{});
            return error.X11InitializationFailed;
        };

        const xic = x11.XCreateIC(
            xim,
            x11.XNInputStyle,
            x11.XIMPreeditNothing | x11.XIMStatusNothing,
            x11.XNClientWindow,
            window,
            x11.XNFocusWindow,
            window,
            @as(usize, 0),
        );
        if (xic == null) {
            std.debug.print("Cannot initialize input context\n", .{});
            return error.X11InitializationFailed;
        }

        return .{
            .display = display,
            .xim = xim,
            .xic = xic,
        };
    }

    pub fn deinit(self: *X11InputContext) void {
        x11.XDestroyIC(self.xic);
        _ = x11.XCloseIM(self.xim);
    }

    pub fn lookupString(
        self: *X11InputContext,
        device_event: *const x11.XIDeviceEvent,
        key_data: *KeyData,
    ) c_int {
        var e: x11.XKeyPressedEvent = std.mem.zeroInit(
            x11.XKeyPressedEvent,
            .{
                .type = x11.XI_KeyPress,
                .display = self.display,
                .time = device_event.time,
                .state = @as(c_uint, @intCast(device_event.mods.effective)),
                .keycode = @as(c_uint, @intCast(device_event.detail)),
                .same_screen = 1,
            },
        );
        var status: x11.Status = undefined;
        const len = x11.Xutf8LookupString(
            self.xic,
            &e,
            &key_data.string,
            32,
            &key_data.keysym,
            &status,
        );
        key_data.symbol = x11.XKeysymToString(key_data.keysym);
        return len;
    }
};

var run_x11_thread: bool = true;
var x11_thread_active: bool = false;

var keyboard: kle.Keyboard = undefined;
var key_states: []KeyOnScreen = undefined;
var keycode_keyboard_lookup = [_]i32{-1} ** 256;

// queue for passing key data from producer (x11 listening thread) to consumer (app loop)
var keys = SpscQueue(32, KeyData).init();
var last_char_timestamp: i64 = 0;

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

fn updateKeyStates(keycode: usize, pressed: bool) void {
    const lookup: i32 = keycode_keyboard_lookup[keycode];
    if (lookup >= 0) {
        const index: usize = @intCast(lookup);
        key_states[index].pressed = pressed;
    }
}

fn xiSetMask(ptr: []u8, event: usize) void {
    const offset: u3 = @truncate(event);
    ptr[event >> 3] |= @as(u8, 1) << offset;
}

fn selectEvents(display: ?*x11.Display, win: x11.Window) void {
    const mask_len = x11.XIMaskLen(x11.XI_LASTEVENT);

    var flags = [_]u8{0} ** mask_len;
    xiSetMask(&flags, x11.XI_KeyPress);
    xiSetMask(&flags, x11.XI_KeyRelease);

    var mask: x11.XIEventMask = undefined;
    mask.deviceid = x11.XIAllDevices;
    mask.mask_len = mask_len;
    mask.mask = &flags;

    _ = x11.XISelectEvents(display.?, win, &mask, 1);
    _ = x11.XSync(display.?, 0);
}

fn x11Listener(app_window: x11.Window, record_file: ?[]const u8) !void {
    defer {
        std.debug.print("defer x11Listener\n", .{});
        x11_thread_active = false;
    }
    x11_thread_active = true;

    const display: *x11.Display = x11.XOpenDisplay(null) orelse {
        std.debug.print("Unable to connect to X server\n", .{});
        return error.X11InitializationFailed;
    };

    var event: c_int = 0;
    var err: c_int = 0;
    var xi_opcode: i32 = 0;

    // TODO: use buffered writer, to do that we must gracefully handle this thread exit,
    // otherwise there is no good place to ensure writer flush
    // TODO: support full file path
    var event_file: ?fs.File = null;
    if (record_file) |filename| {
        const cwd = fs.cwd();
        event_file = try cwd.createFile(filename, .{});
    }
    defer event_file.?.close();

    if (x11.XQueryExtension(display, "XInputExtension", &xi_opcode, &event, &err) == 0) {
        std.debug.print("X Input extension not available.\n", .{});
        return error.X11InitializationFailed;
    }

    const root_window: x11.Window = x11.DefaultRootWindow(display);
    defer {
        _ = x11.XDestroyWindow(display, root_window);
    }

    selectEvents(display, root_window);

    var input_ctx = try X11InputContext.init(display, app_window);
    defer input_ctx.deinit();

    while (true) {
        // x11 wait for event (only key press/release selected)
        var ev: x11.XEvent = undefined;
        const cookie: *x11.XGenericEventCookie = @ptrCast(&ev.xcookie);
        // blocks, makes this thread impossible to exit:
        // TODO: maybe use alarms?
        // https://nrk.neocities.org/articles/x11-timeout-with-xsyncalarm
        _ = x11.XNextEvent(display, &ev);

        if (x11.XGetEventData(display, cookie) != 0 and
            cookie.type == x11.GenericEvent and
            cookie.extension == xi_opcode)
        {
            switch (cookie.evtype) {
                x11.XI_KeyPress, x11.XI_KeyRelease => {
                    const device_event: *x11.XIDeviceEvent = @alignCast(@ptrCast(cookie.data));
                    const keycode: usize = @intCast(device_event.detail);

                    if (event_file) |file| {
                        const device_event_data: [*]u8 = @ptrCast(device_event);
                        _ = try file.writeAll(device_event_data[0..@sizeOf(x11.XIDeviceEvent)]);
                    }

                    updateKeyStates(keycode, cookie.evtype == x11.XI_KeyPress);

                    if (cookie.evtype == x11.XI_KeyPress) {
                        last_char_timestamp = std.time.timestamp();
                        var key: KeyData = std.mem.zeroInit(KeyData, .{});
                        _ = input_ctx.lookupString(device_event, &key);

                        while (!keys.push(key)) : ({
                            // this is unlikely scenario - normal typing would not be fast enough
                            std.debug.print("Consumer outpaced, try again\n", .{});
                            std.time.sleep(10 * std.time.ns_per_ms);
                        }) {}
                        std.debug.print("Produced: '{any}'\n", .{key});
                    }
                },
                else => {},
            }
        }

        x11.XFreeEventData(display, cookie);
    }

    _ = x11.XSync(display, 0);
    _ = x11.XCloseDisplay(display);
}

// uses events stored in file to reproduce them
// assumes that only expected event types are recorded
fn x11Producer(app_window: x11.Window, replay_file: []const u8, loop: bool) !void {
    defer {
        std.debug.print("defer x11Producer\n", .{});
        x11_thread_active = false;
    }
    x11_thread_active = true;

    const display: *x11.Display = x11.XOpenDisplay(null) orelse {
        std.debug.print("Unable to connect to X server\n", .{});
        return error.X11InitializationFailed;
    };

    var input_ctx = try X11InputContext.init(display, app_window);
    defer input_ctx.deinit();

    var run_loop = true;
    std.debug.print("Replay events from file\n", .{});

    // TODO: support full path of a file
    const file = try fs.cwd().openFile(replay_file, .{});
    defer file.close();
    var buf_reader = std.io.bufferedReader(file.reader());
    const reader = buf_reader.reader();

    out: while (run_loop) {
        // Simulate (approximately) timings of recorded events.
        // This ignores effect of added delay due to the loop.
        var events_count: usize = 0;
        var timestamp: x11.Time = 0; // timestamp in x11 events is in milliseconds
        var previous_timestamp: x11.Time = 0;

        while (reader.readStruct(x11.XIDeviceEvent)) |device_event| {
            if (!run_x11_thread) {
                break :out;
            }
            timestamp = device_event.time;
            const time_to_wait = timestamp - previous_timestamp;
            // first would be large because it is in reference to x11 server start,
            // delay only on 1..n event
            if (events_count != 0 and time_to_wait != 0) {
                std.time.sleep(time_to_wait * std.time.ns_per_ms);
            }

            // do stuff with event-from-file

            updateKeyStates(
                @intCast(device_event.detail),
                device_event.evtype == x11.XI_KeyPress,
            );

            if (device_event.evtype == x11.XI_KeyPress) {
                last_char_timestamp = std.time.timestamp();
                var key: KeyData = std.mem.zeroInit(KeyData, .{});
                _ = input_ctx.lookupString(&device_event, &key);

                while (!keys.push(key)) : ({
                    // this is unlikely scenario - normal typing would not be fast enough
                    std.debug.print("Consumer outpaced, try again\n", .{});
                    std.time.sleep(10 * std.time.ns_per_ms);
                }) {}
                std.debug.print("Produced (fake): '{any}'\n", .{key});
            }

            // continue with next events
            previous_timestamp = timestamp;
            events_count += 1;
        } else |err| switch (err) {
            error.EndOfStream => {
                std.debug.print("End of file\n", .{});
                if (loop) {
                    try file.seekTo(0);
                    for (key_states, 0..) |_, i| {
                        var s = &key_states[i];
                        s.pressed = false;
                    }
                } else {
                    run_loop = false;
                }
            },
            else => return err,
        }
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

    _ = try app_config.loadFromFile(config_path);

    const typing_font_size = app_config.data.typing_font_size;
    const typing_font_color: rl.Color = rl.Color.fromInt(app_config.data.typing_font_color);
    const layout_path = app_config.data.layout_path;
    const theme_name = app_config.data.theme;

    var config_watch = try config.Watch.init(config_path);
    defer config_watch.deinit();

    // argument validation

    if (res.args.replay) |replay_file| {
        // just checking if it exist
        const f = try cwd.openFile(replay_file, .{});
        f.close();
    }

    const kle_str_default = @embedFile("resources/keyboard-layout.json");
    var kle_str: []u8 = undefined;

    // TODO: clean up this path handling, resolving real path probably should be done by AppConfg
    if (layout_path.len != 0) {
        std.debug.print("layout = {s}\n", .{layout_path});
        var dir = try cwd.openDir(config_dir, .{});
        defer dir.close();
        const real_layout_path = try dir.realpathAlloc(allocator, layout_path);
        defer allocator.free(real_layout_path);
        std.debug.print("real layout = {s}\n", .{real_layout_path});
        var layout_file = try cwd.openFile(real_layout_path, .{});
        defer layout_file.close();
        const file_size = (try layout_file.stat()).size;
        kle_str = try cwd.readFileAlloc(allocator, real_layout_path, file_size);
    } else {
        kle_str = try allocator.alloc(u8, kle_str_default.len);
        @memcpy(kle_str, kle_str_default);
    }

    const keyboard_parsed = try kle.parseFromSlice(allocator, kle_str);
    defer {
        allocator.free(kle_str);
        keyboard_parsed.deinit();
    }

    keyboard = keyboard_parsed.value;
    key_states = try allocator.alloc(KeyOnScreen, keyboard.keys.len);
    defer allocator.free(key_states);

    for (keyboard.keys, 0..) |k, index| {
        var s = &key_states[index];

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

    // calculate key lookup
    for (keyboard.keys, 0..) |key, index| {
        const label = key.labels[0];
        if (label) |l| {
            var iter = std.mem.split(u8, l, ",");
            while (iter.next()) |part| {
                const integer = try std.fmt.parseInt(u8, part, 10);
                keycode_keyboard_lookup[@as(usize, integer)] = @intCast(index);
            }
        }
    }

    const bbox = try keyboard.calculateBoundingBox();
    const width: c_int = @intFromFloat(bbox.w * KEY_1U_PX);
    const height: c_int = @intFromFloat(bbox.h * KEY_1U_PX);
    std.debug.print("Canvas: {}x{}\n", .{ width, height });

    var renderer: ?Ffmpeg = null;
    var pixels: ?[]u8 = null;
    if (res.args.render) |dst| {
        // TODO: check if ffmpeg installed
        renderer = try Ffmpeg.spawn(@intCast(width), @intCast(height), dst, allocator);
        pixels = try allocator.alloc(u8, @as(usize, @intCast(width * height)) * 4);
    }
    defer if (pixels) |p| allocator.free(p);


    rl.setConfigFlags(.{ .msaa_4x_hint = true, .vsync_hint = true, .window_highdpi = true });
    rl.initWindow(width, height, "klawa");
    defer rl.closeWindow();

    const monitor_refreshrate = rl.getMonitorRefreshRate(rl.getCurrentMonitor());
    std.debug.print("Current monitor refresh rate: {}\n", .{monitor_refreshrate});

    const app_window = glfw.getX11Window(@ptrCast(rl.getWindowHandle()));
    std.debug.print("Application x11 window handle: 0x{X}\n", .{app_window});

    // TODO: is this even needed?
    rl.setTargetFPS(60);

    var thread: ?std.Thread = null;
    if (res.args.replay) |replay_file| {
        // TODO: this will start processing events before rendering ready, add synchronization
        const loop = res.args.@"replay-loop" != 0;
        thread = try std.Thread.spawn(.{}, x11Producer, .{ app_window, replay_file, loop });
    } else {
        // TODO: assign to thread var when close supported, join on this thread won't work now
        _ = try std.Thread.spawn(.{}, x11Listener, .{ app_window, res.args.record });
    }
    defer if (thread) |t| {
        t.join();
    };

    // TODO: make this optional/configurable:
    rl.setWindowState(.{ .window_undecorated = true });

    rl.setExitKey(rl.KeyboardKey.key_null);

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

    var frame_cnt: usize = 0;

    while (!exit_window) {
        if (rl.windowShouldClose()) {
            exit_window = true;
        }

        if (rl.isMouseButtonPressed(rl.MouseButton.mouse_button_right)) {
            std.debug.print("Toggle settings\n", .{});
            show_gui = !show_gui;
        }

        // TODO: should catch errors here
        if (try config_watch.checkForChanges()) {
            std.debug.print("Config file change detected\n", .{});
            const changes = try app_config.loadFromFile(config_path);
            var iter = changes.iterator();
            while (iter.next()) |v| switch(v) {
                .layout_path => std.debug.print("should reload layout path to '{s}' (not supported yet)\n", .{app_config.data.layout_path}),
                .theme => std.debug.print("should reload theme to '{s}' (not supported yet)\n", .{app_config.data.theme}),
                else => {},
            };
        }

        if (keys.pop()) |k| {
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

        for (key_states) |k| {
            var dst = k.dst;
            if (k.pressed) dst.y += 5;
            // TODO: tint color should be configurable
            const tint = if (k.pressed) rl.Color.red else rl.Color.white;
            rl.drawTexturePro(keycap_texture, k.src, dst, rot, k.angle, tint);
        }

        if (app_config.data.show_typing and
            std.time.timestamp() - last_char_timestamp <= typing_persistance_sec) {
            rl.drawRectangle(
                0,
                @divTrunc(height - typing_font_size, 2),
                width,
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
                        .x = @floatFromInt(@divTrunc(width - typing_glyph_width, 2) - offset),
                        .y = @floatFromInt(@divTrunc(height - typing_font_size, 2)),
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
                width,
                height,
                rl.Color{ .r = 255, .g = 255, .b = 255, .a = 196 },
            );

            if (1 == rgui.guiButton(
                .{
                    .x = @floatFromInt(width - 48 - exit_text_width),
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

            if (!x11_thread_active) {
                exit_window = true;
            }
        }

        frame_cnt += 1;
    }

    // NOTE: not able to stop x11Listener yet, applicable only for x11Producer
    run_x11_thread = false;

    if (renderer) |*r| try r.wait();

    std.debug.print("Exit\n", .{});
}

