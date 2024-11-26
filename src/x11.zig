const std = @import("std");
const fs = std.fs;
const posix = std.posix;

const x11 = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/extensions/XInput2.h");
});
const glfw = struct {
    pub const GLFWwindow = opaque {};
    // these should be exported in libraylib.a:
    pub extern "c" fn glfwGetX11Window(window: ?*GLFWwindow) x11.Window;
    pub const getX11Window = glfwGetX11Window;
};

const AppState = @import("main.zig").AppState;
const KeyData = @import("main.zig").KeyData;

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
        return len;
    }
};

var is_running: bool = false;

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

pub fn listener(app_state: *AppState, window_handle: *anyopaque) !void {
    is_running = true;

    const app_window = glfw.getX11Window(@ptrCast(window_handle));
    std.debug.print("Application x11 window handle: 0x{X}\n", .{app_window});

    const display: *x11.Display = x11.XOpenDisplay(null) orelse {
        std.debug.print("Unable to connect to X server\n", .{});
        return error.X11InitializationFailed;
    };

    var event: c_int = 0;
    var err: c_int = 0;
    var xi_opcode: i32 = 0;

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

    var fd = [1]posix.pollfd{posix.pollfd{
        .fd = x11.ConnectionNumber(display),
        .events = posix.POLL.IN,
        .revents = undefined,
    }};

    var ev: x11.XEvent = undefined;
    const cookie: *x11.XGenericEventCookie = @ptrCast(&ev.xcookie);

    while (is_running) {
        // Use poll to give this thread a chance for clean exit
        const pending = x11.XPending(display) > 0 or try posix.poll(&fd, 100) > 0;
        if (!pending) continue;

        // Wait for event (only key press/release selected), should not block since
        // we got here after poll but there is no documented guarantee.
        // This relies on implementation details of x11, see [1] for problem description.
        // [1] https://nrk.neocities.org/articles/x11-timeout-with-xsyncalarm
        _ = x11.XNextEvent(display, &ev);

        if (x11.XGetEventData(display, cookie) != 0 and
            cookie.type == x11.GenericEvent and
            cookie.extension == xi_opcode)
        {
            switch (cookie.evtype) {
                x11.XI_KeyPress, x11.XI_KeyRelease => {
                    const device_event: *x11.XIDeviceEvent = @alignCast(@ptrCast(cookie.data));
                    // offset by 8 to map x11 codes to linux input event codes
                    // (defined in linux/input-event-codes.h system header):
                    const keycode: u8 = @intCast(device_event.detail - 8);

                    var key: KeyData = std.mem.zeroInit(KeyData, .{});
                    key.keycode = keycode;

                    if (cookie.evtype == x11.XI_KeyPress) {
                        key.pressed = true;
                        _ = input_ctx.lookupString(device_event, &key);

                        if (key.string[0] != 0) {
                            // update only for keys which produce output,
                            // this will not include modifiers
                            app_state.last_char_timestamp = std.time.timestamp();
                        }
                    } else {
                        key.pressed = false;
                    }

                    while (!app_state.keys.push(key)) : ({
                        // this is unlikely scenario - normal typing would not be fast enough
                        std.debug.print("Consumer outpaced, try again\n", .{});
                        std.time.sleep(10 * std.time.ns_per_ms);
                    }) {}
                    std.debug.print("Produced: '{any}'\n", .{key});
                },
                else => {},
            }
        }

        x11.XFreeEventData(display, cookie);
    }

    _ = x11.XSync(display, 0);
    _ = x11.XCloseDisplay(display);

    std.debug.print("Exit x11 listener\n", .{});
}

pub fn stop() void {
    is_running = false;
}

pub fn keysymToString(keysym: c_ulong) [*c]const u8 {
    return x11.XKeysymToString(keysym);
}

pub fn getMousePosition() !struct { x: usize, y: usize } {
    // Open a connection to the X server
    const display: *x11.Display = x11.XOpenDisplay(null) orelse {
        std.debug.print("Unable to connect to X server\n", .{});
        return error.X11InitializationFailed;
    };
    defer _ = x11.XCloseDisplay(display);

    // Get the root window for the current screen
    const screen = x11.XDefaultScreen(display);
    const root: x11.Window = x11.XRootWindow(display, screen);
    defer _ = x11.XDestroyWindow(display, root);

    var root_return: x11.Window = undefined;
    var child_return: x11.Window = undefined;
    var root_x_return: i32 = -1;
    var root_y_return: i32 = -1;
    var win_x_return: i32 = 0;
    var win_y_return: i32 = 0;
    var mask_return: u32 = 0;

    _ = x11.XQueryPointer(
        display,
        root,
        &root_return,
        &child_return,
        &root_x_return,
        &root_y_return,
        &win_x_return,
        &win_y_return,
        &mask_return,
    );

    if (root_x_return == -1 or root_y_return == -1) {
        return error.MouseError;
    }

    return .{
        .x = @intCast(root_x_return),
        .y = @intCast(root_y_return),
    };
}
