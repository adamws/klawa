const clap = @import("clap");
const rl = @import("raylib");
const rgui = @import("raygui");
const std = @import("std");

const x11 = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/extensions/XInput2.h");
});

const math = @import("math.zig");
const kle = @import("kle.zig");
const SpscQueue = @import("spsc_queue.zig").SpscQueue;

const glfw = struct {
    pub const GLFWwindow = opaque {};
    // this should be exported in libraylib.a:
    pub extern fn glfwGetX11Window(window: ?*GLFWwindow) x11.Window;
};

pub const KEY_1U_PX = 64;

pub const KeyOnScreen = struct {
    src: rl.Rectangle,
    dst: rl.Rectangle,
    angle: f32,
    pressed: bool,
};

pub const KeyData = struct {
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

var keyboard: kle.Keyboard = undefined;
var key_states: []KeyOnScreen = undefined;
var keycode_keyboard_lookup = [_]i32{-1} ** 256;

// queue for passing key data from producer (x11 listening thread) to consumer (app loop)
var keys = SpscQueue(32, KeyData).init();
var last_char_timestamp: i64 = 0;

// https://github.com/bits/UTF-8-Unicode-Test-Documents/blob/master/UTF-8_sequence_unseparated/utf8_sequence_0-0xfff_assigned_printable_unseparated.txt
const text = @embedFile("resources/utf8_sequence_0-0xfff_assigned_printable_unseparated.txt");
// TODO: symbols subsitution should be configurable, not all fonts will have these:
const symbols = "↚";
const all_text = text ++ symbols;

const font_data = @embedFile("resources/Hack-Regular.ttf");

const record_events = false;
const replay_events = true;

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

fn x11Listener(app_window: x11.Window) !void {
    defer {
        std.debug.print("defer x11Listener\n", .{});
    }
    var display: ?*x11.Display = null;

    var event: c_int = 0;
    var err: c_int = 0;
    var xi_opcode: i32 = 0;

    // TODO: use buffered writer, to do that we must gracefuly handle this thread exit,
    // otherwise there is no good place to ensure writer flush
    var event_file: ?std.fs.File = null;
    if (record_events) {
        const cwd = std.fs.cwd();
        event_file = try cwd.createFile("events.txt", .{});
    }
    defer event_file.?.close();

    display = x11.XOpenDisplay(null);
    if (display == null) {
        std.debug.print("Unable to connect to X server\n", .{});
        return error.X11InitializationFailed;
    }

    if (x11.XQueryExtension(display.?, "XInputExtension", &xi_opcode, &event, &err) == 0) {
        std.debug.print("X Input extension not available.\n", .{});
        return error.X11InitializationFailed;
    }

    const root_window: x11.Window = x11.DefaultRootWindow(display.?);
    defer {
        _ = x11.XDestroyWindow(display.?, root_window);
    }

    selectEvents(display, root_window);

    const xim = x11.XOpenIM(display.?, null, null, null);
    if (xim == null) {
        std.debug.print("Cannot initialize input method\n", .{});
        return error.X11InitializationFailed;
    }
    defer _ = x11.XCloseIM(xim);

    const xic = x11.XCreateIC(
        xim,
        x11.XNInputStyle,
        x11.XIMPreeditNothing | x11.XIMStatusNothing,
        x11.XNClientWindow,
        app_window,
        x11.XNFocusWindow,
        app_window,
    );
    if (xic == null) {
        std.debug.print("Cannot initialize input context\n", .{});
        return error.X11InitializationFailed;
    }
    defer x11.XDestroyIC(xic);

    while (true) {
        // x11 wait for event (only key press/release selected)
        var ev: x11.XEvent = undefined;
        const cookie: *x11.XGenericEventCookie = @ptrCast(&ev.xcookie);
        // blocks, makes this thread impossible to exit:
        // TODO: maybe use alarms?
        // https://nrk.neocities.org/articles/x11-timeout-with-xsyncalarm
        _ = x11.XNextEvent(display.?, &ev);

        if (x11.XGetEventData(display.?, cookie) != 0 and
            cookie.type == x11.GenericEvent and
            cookie.extension == xi_opcode)
        {
            switch (cookie.evtype) {
                x11.XI_KeyPress, x11.XI_KeyRelease => {
                    const device_event: *x11.XIDeviceEvent = @alignCast(@ptrCast(cookie.data));
                    const keycode: usize = @intCast(device_event.detail);

                    const lookup: i32 = keycode_keyboard_lookup[keycode];
                    if (lookup >= 0) {
                        const index: usize = @intCast(lookup);
                        key_states[index].pressed = cookie.evtype == x11.XI_KeyPress;
                    }

                    if (event_file) |file| {
                        const device_event_data: [*]u8 = @ptrCast(device_event);
                        _ = try file.writeAll(device_event_data[0..@sizeOf(x11.XIDeviceEvent)]);
                    }

                    if (cookie.evtype == x11.XI_KeyPress) {
                        var e: x11.XKeyPressedEvent = .{
                            .type = x11.XI_KeyPress,
                            .display = display,
                            .window = root_window,
                            .root = root_window,
                            .subwindow = 0,
                            .time = device_event.time,
                            .x = 0,
                            .y = 0,
                            .x_root = 0,
                            .y_root = 0,
                            .state = @intCast(device_event.mods.effective),
                            .keycode = @intCast(keycode),
                            .same_screen = 1,
                        };
                        var char_buffer = [_]u8{0} ** 32;
                        var keysym: x11.KeySym = undefined;
                        var status: x11.Status = undefined;
                        const len = x11.Xutf8LookupString(xic, &e, &char_buffer, 32, &keysym, &status);
                        last_char_timestamp = std.time.timestamp();
                        std.debug.print(
                            "time: {} status: {any} keycode: {d} keysym: 0x{X} buffer({}): '{s}'\n",
                            .{
                                last_char_timestamp,
                                status,
                                keycode,
                                keysym,
                                len,
                                std.fmt.fmtSliceHexLower(&char_buffer),
                            },
                        );

                        const key: KeyData = .{
                            .pressed = true,
                            .repeated = false,
                            .keycode = @intCast(keycode),
                            .keysym = keysym,
                            .status = status,
                            .symbol = x11.XKeysymToString(keysym),
                            .string = char_buffer,
                        };

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

        x11.XFreeEventData(display.?, cookie);
    }

    _ = x11.XSync(display.?, 0);
    _ = x11.XCloseDisplay(display.?);
}

// uses events stored in file to reproduce them
// assumes that only expected event types are recorded
fn x11Producer(app_window: x11.Window) !void {
    defer {
        std.debug.print("defer x11Producer\n", .{});
    }

    var display: ?*x11.Display = null;
    display = x11.XOpenDisplay(null);
    if (display == null) {
        std.debug.print("Unable to connect to X server\n", .{});
        return error.X11InitializationFailed;
    }

    const xim = x11.XOpenIM(display.?, null, null, null);
    if (xim == null) {
        std.debug.print("Cannot initialize input method\n", .{});
        return error.X11InitializationFailed;
    }
    defer _ = x11.XCloseIM(xim);

    const xic = x11.XCreateIC(
        xim,
        x11.XNInputStyle,
        x11.XIMPreeditNothing | x11.XIMStatusNothing,
        x11.XNClientWindow,
        app_window,
        x11.XNFocusWindow,
        app_window,
    );
    if (xic == null) {
        std.debug.print("Cannot initialize input context\n", .{});
        return error.X11InitializationFailed;
    }
    defer x11.XDestroyIC(xic);

    const file = try std.fs.cwd().openFile("events.txt", .{});
    defer file.close();
    var buf_reader = std.io.bufferedReader(file.reader());
    const reader = buf_reader.reader();

    // Simulate (approximately) timings of recorded events.
    // This ignores effect of added delay due to the loop.
    var events_count: usize = 0;
    var timestamp: x11.Time = 0; // timestamp in x11 events is in milliseconds
    var previous_timestamp: x11.Time = 0;
    while (reader.readStruct(x11.XIDeviceEvent)) |event| {
        timestamp = event.time;
        const time_to_wait = timestamp - previous_timestamp;
        std.debug.print("Should wait {} ms before emitting fake event\n", .{time_to_wait});
        // first would be large because it is in reference to x11 server start,
        // delay only on 1..n event
        if (events_count != 0 and time_to_wait != 0) {
            std.time.sleep(time_to_wait * std.time.ns_per_ms);
        }
        std.debug.print("{}: event: '{any}'\n", .{timestamp, event});

        // do stuff with event-from-file
        // TODO: duplicate code, refactor, probably should move
        // x11 stuff to another file already
        const keycode: usize = @intCast(event.detail);
        const lookup: i32 = keycode_keyboard_lookup[keycode];
        if (lookup >= 0) {
            const index: usize = @intCast(lookup);
            key_states[index].pressed = event.evtype == x11.XI_KeyPress;
        }
        if (event.evtype == x11.XI_KeyPress) {
            var e: x11.XKeyPressedEvent = .{
                .type = x11.XI_KeyPress,
                .display = display,
                .window = app_window,
                .root = app_window,
                .subwindow = 0,
                .time = event.time,
                .x = 0,
                .y = 0,
                .x_root = 0,
                .y_root = 0,
                .state = @intCast(event.mods.effective),
                .keycode = @intCast(keycode),
                .same_screen = 1,
            };
            var char_buffer = [_]u8{0} ** 32;
            var keysym: x11.KeySym = undefined;
            var status: x11.Status = undefined;
            const len = x11.Xutf8LookupString(xic, &e, &char_buffer, 32, &keysym, &status);
            last_char_timestamp = std.time.timestamp();
            std.debug.print(
                "time: {} status: {any} keycode: {d} keysym: 0x{X} buffer({}): '{s}'\n",
                .{
                    last_char_timestamp,
                    status,
                    keycode,
                    keysym,
                    len,
                    std.fmt.fmtSliceHexLower(&char_buffer),
                },
            );

            const key: KeyData = .{
                .pressed = true,
                .repeated = false,
                .keycode = @intCast(keycode),
                .keysym = keysym,
                .status = status,
                .symbol = x11.XKeysymToString(keysym),
                .string = char_buffer,
            };

            while (!keys.push(key)) : ({
                // this is unlikely scenario - normal typing would not be fast enough
                std.debug.print("Consumer outpaced, try again\n", .{});
                std.time.sleep(10 * std.time.ns_per_ms);
            }) {}
            std.debug.print("Produced: '{any}'\n", .{key});
        }

        // continue with next events
        previous_timestamp = timestamp;
        events_count += 1;
    } else |err| switch (err) {
        error.EndOfStream => {
            std.debug.print("End of file", .{});
        },
        else => return err,
    }

}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-l, --layout <str>     Keyboard layout json file.
        \\
    );

    var res = try clap.parse(clap.Help, &params, clap.parsers.default, .{ .allocator = allocator });
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{
            .spacing_between_parameters = 0,
        });
    }

    const kle_str_default = @embedFile("resources/keyboard-layout.json");
    var kle_str: []u8 = undefined;

    if (res.args.layout) |n| {
        std.debug.print("--layout = {s}\n", .{n});
        var layout_file = try std.fs.cwd().openFile(n, .{});
        defer layout_file.close();
        const file_size = (try layout_file.stat()).size;
        kle_str = try std.fs.cwd().readFileAlloc(allocator, n, file_size);
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
        if (k.width == 1.25 and k.width2 == 1.5 and k.height == 2 and k.height2 == 1) {
            s.src.x = 2 * KEY_1U_PX;
            s.src.y = 0;
            s.dst.x -= 0.25 * KEY_1U_PX;
        }

        s.pressed = false;
    }

    // calculate key lookup
    for (keyboard.keys, 0..) |key, index| {
        const label = key.labels[0];
        if (label) |l| {
            var iter = std.mem.split(u8, l, ",");
            while (iter.next()) |part| {
                std.debug.print("{}: label: {s}\n", .{ index, part });
                const integer = try std.fmt.parseInt(u8, part, 10);
                keycode_keyboard_lookup[@as(usize, integer)] = @intCast(index);
            }
        }
    }

    const bbox = try keyboard.calculateBoundingBox();
    const width: c_int = @intFromFloat(bbox.w * KEY_1U_PX);
    const height: c_int = @intFromFloat(bbox.h * KEY_1U_PX);
    std.debug.print("Canvas: {}x{}\n", .{ width, height });

    rl.setConfigFlags(.{ .msaa_4x_hint = true, .vsync_hint = true, .window_highdpi = true });
    rl.initWindow(width, height, "klawa");
    defer rl.closeWindow();

    const app_window = glfw.glfwGetX11Window(@ptrCast(rl.getWindowHandle()));
    std.debug.print("Application x11 window handle: 0x{X}\n", .{app_window});

    if (replay_events) {
        const thread = try std.Thread.spawn(.{}, x11Producer, .{app_window});
        _ = thread;
    } else {
        const thread = try std.Thread.spawn(.{}, x11Listener, .{app_window});
        _ = thread;
        //defer thread.join();
    }

    // TODO: make this optional/configurable:
    rl.setWindowState(.{ .window_undecorated = true });

    rl.setExitKey(rl.KeyboardKey.key_null);

    const keycaps = @embedFile("resources/keycaps.png");
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

    const typing_font_size = 128;
    // TODO: font should be configurable
    const font = rl.loadFontFromMemory(".ttf", font_data, typing_font_size, codepoints);
    const default_font = rl.getFontDefault();

    const typing_glyph_size = rl.getGlyphAtlasRec(font, 0);
    const typing_glyph_width: c_int = @intFromFloat(typing_glyph_size.width);

    var exit_window = false;
    var show_gui = false;

    const exit_label = "Exit Application";
    const exit_text_width = rl.measureText(exit_label, default_font.baseSize);

    var show_typing = true;
    const show_typing_label = "Show typed characters";

    const typing_persistance_sec = 2;

    var codepoints_buffer = CodepointBuffer{};

    rl.setTargetFPS(60);

    while (!exit_window) {
        if (rl.windowShouldClose()) {
            exit_window = true;
        }

        if (rl.isMouseButtonPressed(rl.MouseButton.mouse_button_right)) {
            std.debug.print("Toggle settings\n", .{});
            show_gui = !show_gui;
        }

        if (keys.pop()) |k| {
            std.debug.print("Consumed: '{s}'\n", .{k.symbol});

            var text_: [*:0]const u8 = undefined;
            // TODO: create comptime symbol lookup table and use it here:
            if (std.mem.eql(u8, std.mem.sliceTo(k.symbol, 0), "BackSpace")) {
                std.debug.print(
                    "replacement for {s} would happen \n",
                    .{k.symbol},
                );
                text_ = "↚";
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
        rl.clearBackground(rl.Color.white);

        const rot = rl.Vector2{ .x = 0, .y = 0 };

        for (key_states) |k| {
            rl.drawTexturePro(keycap_texture, k.src, k.dst, rot, k.angle, rl.Color.white);

            if (k.pressed) {
                rl.drawRectanglePro(
                    k.dst,
                    rot,
                    k.angle,
                    rl.Color{ .r = 255, .g = 0, .b = 0, .a = 128 },
                );
            }
        }

        if (show_typing and std.time.timestamp() - last_char_timestamp <= typing_persistance_sec) {
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
                    typing_font_size,
                    rl.Color.black,
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

            _ = rgui.guiCheckBox(
                .{
                    .x = 16,
                    .y = 16,
                    .width = 32,
                    .height = 32,
                },
                show_typing_label,
                &show_typing,
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

        rl.endDrawing();
    }

    std.debug.print("Exit\n", .{});
}
