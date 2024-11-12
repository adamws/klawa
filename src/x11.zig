const std = @import("std");
const fs = std.fs;

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
        key_data.symbol = x11.XKeysymToString(key_data.keysym);
        return len;
    }
};

pub var x11_thread_active: bool = false;
pub var run_x11_thread: bool = true;

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

pub fn listener(app_state: *AppState, window_handle: *anyopaque, record_file: ?[]const u8) !void {
    defer {
        std.debug.print("defer x11Listener\n", .{});
        x11_thread_active = false;
    }
    x11_thread_active = true;

    const app_window = glfw.getX11Window(@ptrCast(window_handle));
    std.debug.print("Application x11 window handle: 0x{X}\n", .{app_window});

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
                    // offset by 8 to map x11 codes to linux input event codes
                    // (defined in linux/input-event-codes.h system header):
                    const keycode: usize = @intCast(device_event.detail - 8);

                    if (event_file) |file| {
                        const device_event_data: [*]u8 = @ptrCast(device_event);
                        _ = try file.writeAll(device_event_data[0..@sizeOf(x11.XIDeviceEvent)]);
                    }

                    app_state.updateKeyStates(keycode, cookie.evtype == x11.XI_KeyPress);

                    if (cookie.evtype == x11.XI_KeyPress) {
                        var key: KeyData = std.mem.zeroInit(KeyData, .{});
                        _ = input_ctx.lookupString(device_event, &key);

                        if (key.string[0] != 0) {
                            // update only for keys which produe output,
                            // this will not include modifiers
                            app_state.last_char_timestamp = std.time.timestamp();
                        }

                        while (!app_state.keys.push(key)) : ({
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
pub fn producer(app_state: *AppState, window_handle: *anyopaque, replay_file: []const u8, loop: bool) !void {
    defer {
        std.debug.print("defer x11Producer\n", .{});
        x11_thread_active = false;
    }
    x11_thread_active = true;

    const app_window = glfw.getX11Window(@ptrCast(window_handle));
    std.debug.print("Application x11 window handle: 0x{X}\n", .{app_window});

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

            app_state.updateKeyStates(
                @intCast(device_event.detail - 8),
                device_event.evtype == x11.XI_KeyPress,
            );

            if (device_event.evtype == x11.XI_KeyPress) {
                var key: KeyData = std.mem.zeroInit(KeyData, .{});
                _ = input_ctx.lookupString(&device_event, &key);

                if (key.string[0] != 0) {
                    app_state.last_char_timestamp = std.time.timestamp();
                }

                while (!app_state.keys.push(key)) : ({
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
                    for (app_state.key_states, 0..) |_, i| {
                        var s = &app_state.key_states[i];
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

