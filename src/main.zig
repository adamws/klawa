const clap = @import("clap");
const math = @import("math.zig");
const std = @import("std");
const kle = @import("kle.zig");
const sdl = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_image.h");
});
const x11 = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/extensions/XInput2.h");
});

pub const KEY_1U_PX = 64;

var display: ?*x11.Display = null;

var keycap_texture: ?*sdl.SDL_Texture = null;
var keycap_width: i32 = -1;
var keycap_height: i32 = -1;
var xi_opcode: i32 = 0;

var keyboard: kle.Keyboard = undefined;
var key_states: []KeyOnScreen = undefined;
var keycode_keyboard_lookup = [_]i32{-1} ** 256;

pub const KeyOnScreen = struct {
    x: c_int,
    y: c_int,
    angle: f64,
    texture: sdl.struct_SDL_Rect,
    pressed: bool,
};

fn render(renderer: ?*sdl.SDL_Renderer) void {
    _ = sdl.SDL_SetRenderDrawBlendMode(renderer, sdl.SDL_BLENDMODE_BLEND);
    _ = sdl.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 128);

    const rot = sdl.SDL_Point{ .x = 0, .y = 0 };

    for (key_states) |k| {
        var dst = sdl.SDL_Rect{ .x = k.x, .y = k.y, .w = k.texture.w, .h = k.texture.h };
        _ = sdl.SDL_RenderCopyEx(renderer, keycap_texture, &k.texture, &dst, k.angle, &rot, sdl.SDL_FLIP_NONE);
        if (k.pressed) {
            _ = sdl.SDL_RenderFillRect(renderer, &dst);
        }
    }
}

fn xiSetMask(ptr: []u8, event: usize) void {
    const offset: u3 = @truncate(event);
    ptr[event >> 3] |= @as(u8, 1) << offset;
}

fn selectEvents(win: x11.Window) void {
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

fn loop(renderer: ?*sdl.SDL_Renderer) void {
    var running = true;
    var event: sdl.SDL_Event = undefined;

    while (running) {
        _ = sdl.SDL_SetRenderDrawColor(renderer, 200, 200, 200, 255);
        _ = sdl.SDL_RenderClear(renderer);

        // SDL event loop, just for detecting quit
        while (sdl.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                sdl.SDL_QUIT => running = false,
                else => {},
            }
        }

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

        render(renderer);
        sdl.SDL_RenderPresent(renderer);
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
            .spacing_between_parameters = 0
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

        s.angle = k.rotation_angle;
        const angle_rad = std.math.rad_per_deg * s.angle;
        const point = math.Vec2{ .x = k.x, .y = k.y };
        const rot_origin = math.Vec2{ .x = k.rotation_x, .y = k.rotation_y };
        const result = math.rotate_around_center(point, rot_origin, angle_rad);
        s.x = @intFromFloat(KEY_1U_PX * result.x);
        s.y = @intFromFloat(KEY_1U_PX * result.y);

        const width: c_int = @intFromFloat(KEY_1U_PX * @max(k.width, k.width2));
        const height: c_int = @intFromFloat(KEY_1U_PX * @max(k.height, k.height2));
        const texture_y: c_int = @intFromFloat(KEY_1U_PX * (k.width * 4 - 4));

        if (k.width == 1.25 and k.width2 == 1.5 and k.height == 2 and k.height2 == 1) {
            // iso enter
            s.x -= @intFromFloat(0.25 * KEY_1U_PX);
            s.texture = .{ .x = 2 * KEY_1U_PX, .y = 0, .w = width, .h = height };
        } else {
            s.texture = .{ .x = 0, .y = texture_y, .w = width, .h = height };
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


    var event: c_int = 0;
    var err: c_int = 0;

    display = x11.XOpenDisplay(null);
    if (display == null) {
        std.debug.print("Unable to connect to X server\n", .{});
        return error.X11InitializationFailed;
    }

    if (x11.XQueryExtension(display.?, "XInputExtension", &xi_opcode, &event, &err) == 0) {
        std.debug.print("X Input extension not available.\n", .{});
        return error.X11InitializationFailed;
    }

    if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO) < 0) {
        std.debug.print("Failed to initialize SDL\n", .{});
        return error.SDLInitializationFailed;
    }
    defer sdl.SDL_Quit();

    _ = sdl.SDL_EventState(sdl.SDL_KEYDOWN, sdl.SDL_IGNORE);
    _ = sdl.SDL_EventState(sdl.SDL_KEYUP, sdl.SDL_IGNORE);

    var window: ?*sdl.SDL_Window = null;
    var renderer: ?*sdl.SDL_Renderer = null;

    _ = sdl.SDL_CreateWindowAndRenderer(width, height, 0, &window, &renderer);
    defer {
        sdl.SDL_DestroyRenderer(renderer);
        sdl.SDL_DestroyWindow(window);
    }

    _ = sdl.SDL_SetWindowBordered(window, sdl.SDL_FALSE);

    const keycaps = @embedFile("keycaps.png");
    const rw = sdl.SDL_RWFromConstMem(keycaps, keycaps.len) orelse {
        return error.SDLInitializationFailed;
    };
    const keycap_surface: *sdl.SDL_Surface = sdl.IMG_Load_RW(rw, 0) orelse {
        return error.SDLInitializationFailed;
    };
    defer sdl.SDL_FreeSurface(keycap_surface);

    keycap_width = keycap_surface.w;
    keycap_height = keycap_surface.h;
    keycap_texture = sdl.SDL_CreateTextureFromSurface(renderer, keycap_surface);
    defer sdl.SDL_DestroyTexture(keycap_texture);

    const win: x11.Window = x11.DefaultRootWindow(display.?);
    defer {
        _ = x11.XDestroyWindow(display.?, win);
        _ = x11.XSync(display.?, 0);
        _ = x11.XCloseDisplay(display.?);
    }

    selectEvents(win);

    // render once before loop because loop blocks when no x11 events
    _ = sdl.SDL_SetRenderDrawColor(renderer, 200, 200, 200, 255);
    _ = sdl.SDL_RenderClear(renderer);
    render(renderer);
    sdl.SDL_RenderPresent(renderer);

    loop(renderer);
}
