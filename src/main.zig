const std = @import("std");
const keyboard = @import("keyboard.zig");
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

fn render(renderer: ?*sdl.SDL_Renderer) void {
    _ = sdl.SDL_SetRenderDrawBlendMode(renderer, sdl.SDL_BLENDMODE_BLEND);
    _ = sdl.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 128);

    for (keyboard.layout) |k| {
        const x: c_int = @intFromFloat(KEY_1U_PX * k.x);
        const y: c_int = @intFromFloat(KEY_1U_PX * k.y);
        const width: c_int = @intFromFloat(KEY_1U_PX * @max(k.width, k.width2));
        const height: c_int = @intFromFloat(KEY_1U_PX * @max(k.height, k.height2));
        const texture_y: c_int = @intFromFloat(KEY_1U_PX * (k.width * 4 - 4));
        var src = sdl.SDL_Rect{ .x = 0, .y = texture_y, .w = width, .h = height };
        var dst = sdl.SDL_Rect{ .x = x, .y = y, .w = width, .h = height };

        if (k.width == 1.25 and k.width2 == 1.5 and k.height == 2 and k.height2 == 1) {
            // iso enter
            src.x = 2 * KEY_1U_PX;
            src.y = 0;
            dst.x -= @intFromFloat(0.25 * KEY_1U_PX);
        }

        _ = sdl.SDL_RenderCopy(renderer, keycap_texture, &src, &dst);
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
            cookie.extension == xi_opcode) {
            const raw_event: *x11.XIRawEvent = @alignCast(@ptrCast(cookie.data));
            switch (cookie.evtype) {
                x11.XI_RawKeyPress, x11.XI_RawKeyRelease => {
                    const keycode: usize = @intCast(raw_event.detail);
                    std.debug.print("keycode: {}\n", .{keycode});
                    const lookup: i32 = keyboard.keycode_keyboard_lookup[keycode];
                    if (lookup >= 0) {
                        const index: usize = @intCast(lookup);
                        keyboard.layout[index].pressed = cookie.evtype == x11.XI_RawKeyPress;
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
    var event: c_int = 0;
    var err: c_int = 0;

    display = x11.XOpenDisplay(null);
    if (display == null) {
        std.debug.print("Unable to connect to X server\n", .{});
        return;
    }

    if (x11.XQueryExtension(display.?, "XInputExtension", &xi_opcode, &event, &err) == 0) {
        std.debug.print("X Input extension not available.\n", .{});
        return;
    }

    if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO) < 0) {
        std.debug.print("Failed to initialize SDL\n", .{});
        return;
    }
    defer sdl.SDL_Quit();

    _ = sdl.SDL_EventState(sdl.SDL_KEYDOWN, sdl.SDL_IGNORE);
    _ = sdl.SDL_EventState(sdl.SDL_KEYUP, sdl.SDL_IGNORE);

    var window: ?*sdl.SDL_Window = null;
    var renderer: ?*sdl.SDL_Renderer = null;

    const width = 960;
    const height = 320;
    _ = sdl.SDL_CreateWindowAndRenderer(width, height, 0, &window, &renderer);
    defer sdl.SDL_DestroyRenderer(renderer);
    defer sdl.SDL_DestroyWindow(window);

    _ = sdl.SDL_SetWindowBordered(window, sdl.SDL_FALSE);

    const keycap_surface: *sdl.SDL_Surface = sdl.IMG_Load("assets/keycaps.png")
        orelse return error.FileNotFound;
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

    loop(renderer);
}
