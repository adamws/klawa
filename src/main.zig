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

pub const KEY_1U_PX = 64;

var keyboard: kle.Keyboard = undefined;
var key_states: []KeyOnScreen = undefined;
var keycode_keyboard_lookup = [_]i32{-1} ** 256;

pub const KeyOnScreen = struct {
    src: rl.Rectangle,
    dst: rl.Rectangle,
    angle: f32,
    pressed: bool,
};

fn xiSetMask(ptr: []u8, event: usize) void {
    const offset: u3 = @truncate(event);
    ptr[event >> 3] |= @as(u8, 1) << offset;
}

fn selectEvents(display: ?*x11.Display, win: x11.Window) void {
    const mask_len = x11.XIMaskLen(x11.XI_LASTEVENT);

    var flags = [_]u8{0} ** mask_len;
    xiSetMask(&flags, x11.XI_RawKeyPress);
    xiSetMask(&flags, x11.XI_RawKeyRelease);

    var mask: x11.XIEventMask = undefined;
    mask.deviceid = x11.XIAllMasterDevices;
    mask.mask_len = mask_len;
    mask.mask = &flags;

    _ = x11.XISelectEvents(display.?, win, &mask, 1);
    _ = x11.XSync(display.?, 0);
}

fn x11Listener() !void {
    var display: ?*x11.Display = null;

    var event: c_int = 0;
    var err: c_int = 0;
    var xi_opcode: i32 = 0;

    display = x11.XOpenDisplay(null);
    if (display == null) {
        std.debug.print("Unable to connect to X server\n", .{});
        return error.X11InitializationFailed;
    }

    if (x11.XQueryExtension(display.?, "XInputExtension", &xi_opcode, &event, &err) == 0) {
        std.debug.print("X Input extension not available.\n", .{});
        return error.X11InitializationFailed;
    }

    const win: x11.Window = x11.DefaultRootWindow(display.?);
    defer {
        _ = x11.XDestroyWindow(display.?, win);
        _ = x11.XSync(display.?, 0);
        _ = x11.XCloseDisplay(display.?);
    }

    selectEvents(display, win);

    while (true) {
        // x11 wait for event (only raw key presses selected)
        var ev: x11.XEvent = undefined;
        const cookie: *x11.XGenericEventCookie = @ptrCast(&ev.xcookie);
        _ = x11.XNextEvent(display.?, &ev);

        if (x11.XGetEventData(display.?, cookie) != 0 and
            cookie.type == x11.GenericEvent and
            cookie.extension == xi_opcode)
        {
            const raw_event: *x11.XIRawEvent = @alignCast(@ptrCast(cookie.data));
            switch (cookie.evtype) {
                x11.XI_RawKeyPress, x11.XI_RawKeyRelease => {
                    const keycode: usize = @intCast(raw_event.detail);
                    std.debug.print("keycode: {}\n", .{keycode});
                    const lookup: i32 = keycode_keyboard_lookup[keycode];
                    if (lookup >= 0) {
                        const index: usize = @intCast(lookup);
                        key_states[index].pressed = cookie.evtype == x11.XI_RawKeyPress;
                    }
                },
                else => {},
            }
        }

        x11.XFreeEventData(display.?, cookie);
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

    const kle_str_default = @embedFile("keyboard-layout.json");
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

    const thread = try std.Thread.spawn(.{}, x11Listener, .{});
    _ = thread;

    rl.setConfigFlags(.{ .msaa_4x_hint = true, .vsync_hint = true, .window_highdpi = true });
    rl.initWindow(width, height, "klawa");
    defer rl.closeWindow();

    // TODO: make this optional/configurable:
    rl.setWindowState(.{ .window_undecorated = true });

    rl.setExitKey(rl.KeyboardKey.key_null);

    const keycaps = @embedFile("keycaps.png");
    const keycaps_image = rl.loadImageFromMemory(".png", keycaps);
    const keycap_texture = rl.loadTextureFromImage(keycaps_image);
    defer rl.unloadTexture(keycap_texture);

    rl.setTextureFilter(keycap_texture, rl.TextureFilter.texture_filter_bilinear);

    // texture created, image no longer needed
    rl.unloadImage(keycaps_image);

    // TODO: implement font discovery
    // TODO: if not found fallback to default
    const font = rl.loadFont("/usr/share/fonts/TTF/DejaVuSans.ttf");
    const default_font = rl.getFontDefault();

    rl.setTargetFPS(60);

    var exit_window = false;
    var show_gui = false;

    const exit_label = "Exit Application";
    const exit_text_width = rl.measureText(exit_label, default_font.baseSize);

    while (!exit_window) {
        if (rl.windowShouldClose()) {
            exit_window = true;
        }

        if (rl.isMouseButtonPressed(rl.MouseButton.mouse_button_right)) {
            std.debug.print("Toggle settings\n", .{});
            show_gui = !show_gui;
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

        if (show_gui) {
            rl.drawRectangle(
                0,
                0,
                width,
                height,
                rl.Color{ .r = 0, .g = 0, .b = 0, .a = 128 },
            );
            rl.drawTextEx(
                font,
                "Settings menu (todo)",
                .{ .x = 190, .y = 200 },
                32,
                0,
                rl.Color.red,
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
