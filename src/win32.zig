const std = @import("std");
const fs = std.fs;

// References:
// https://learn.microsoft.com/en-us/windows/win32/inputdev/about-keyboard-input

const c = @cImport({
  @cDefine("WINDOWS_LEAN_AND_MEAN", "");
  @cInclude("windows.h");
});

const AppState = @import("main.zig").AppState;
const KeyData = @import("main.zig").KeyData;
const labels_lookup = @import("layout_labels.zig").labels_lookup;

var is_running: bool = false;

var thread_id: c.DWORD = undefined;
var app_state_l: *AppState = undefined;
var layout: c.HKL = undefined;
var hook: ?c.HHOOK = null;

fn keyEventToString(vk: u32, scan_code: u32, string: []u8) !void {
    var keyboard_state: [256]u8 = .{0} ** 256;

    // intentionally ignore c.VK_CONTROL (modifiers are tracked in upper layer), makes it
    // easier to display Ctrl+ key combos
    const modifiers = [_]c_int{c.VK_SHIFT, c.VK_MENU};

    for (modifiers) |m| {
        const value: c_short = c.GetKeyState(m);
        keyboard_state[@as(usize, @intCast(m))] = @bitCast(@as(i8, @truncate(value >> 8)));
    }

    var buffer: [16]u16 = undefined;
    const len: usize = @intCast(c.ToUnicodeEx(vk, scan_code, &keyboard_state, &buffer, buffer.len, 0, layout));
    const buffer_slice = buffer[0..len];

    _ = try std.unicode.utf16LeToUtf8(string, buffer_slice);
}

fn lowLevelKeyboardProc(nCode: c.INT, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.C) c.LRESULT {
    if (nCode == c.HC_ACTION) {
        const keyboard: *const c.KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @intCast(lParam)));

        var key: KeyData = std.mem.zeroInit(KeyData, .{});
        key.keycode = @intCast(keyboard.vkCode);

        keyEventToString(keyboard.vkCode, keyboard.scanCode, &key.string) catch {};
        const extended: bool = ((keyboard.flags & c.LLKHF_EXTENDED) != 0);

        var index = @as(c_ulong, @intCast(keyboard.scanCode));
        if (extended) index += 0x100;
        if (index >= kbd_en_vscname.len) {
            index = 0;
        }
        key.keysym = index;

        if (wParam == c.WM_KEYDOWN or wParam == c.WM_SYSKEYDOWN) {
            key.pressed = true;

            if (key.string[0] != 0) {
                // update only for keys which produce output,
                // this will not include modifiers
                app_state_l.last_char_timestamp = std.time.timestamp();
            }
        } else {
            key.pressed = false;
        }

        while (!app_state_l.keys.push(key)) : ({
            // this is unlikely scenario - normal typing would not be fast enough
            std.debug.print("Consumer outpaced, try again\n", .{});
            std.time.sleep(10 * std.time.ns_per_ms);
        }) {}
        std.debug.print("Produced: '{any}'\n", .{key});
    }
    return c.CallNextHookEx(hook.?, nCode, wParam, lParam);
}

pub fn listener(app_state: *AppState, window_handle: *anyopaque) !void {
    _ = window_handle;
    is_running = true;
    thread_id = c.GetCurrentThreadId();

    app_state_l = app_state;
    layout = c.GetKeyboardLayout(0);

    hook = c.SetWindowsHookExA(c.WH_KEYBOARD_LL, lowLevelKeyboardProc, null, 0).?;
    defer _ = c.UnhookWindowsHookEx(hook.?);

    var msg: c.MSG = undefined;
    while (is_running and c.GetMessageA(&msg, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageA(&msg);
    }
    std.debug.print("Exit win32 listener\n", .{});
}

pub fn stop() void {
    is_running = false;
    _ = c.PostThreadMessageA(thread_id, c.WM_QUIT, 0, 0);
}

pub fn keysymToString(keysym: c_ulong) [*c]const u8 {
    return kbd_en_vscname[@as(usize, @intCast(keysym))].ptr;
}

// must match names used by X11:
const kbd_en_vscname = [_][]const u8 {
    // zig fmt: off
    "", "Escape", "", "", "", "", "", "", "", "", "", "", "", "", "BackSpace", "Tab",
    "", "", "", "", "", "", "", "", "", "", "", "", "Return", "Control_L", "", "",
    "", "", "", "", "", "", "", "", "", "", "Shift_L", "", "", "", "", "",
    "", "", "", "", "", "", "Shift_R", "KP_Multiply", "Alt_L", "space", "Caps_Lock", "F1", "F2", "F3", "F4", "F5",
    "F6", "F7", "F8", "F9", "F10", "Pause", "Scroll_Lock", "KP_7", "KP_8", "KP_9", "KP_Subtract", "KP_4", "KP_5", "KP_6", "KP_Add", "KP_1",
    "KP_2", "KP_3", "KP_0", "KP_Separator", "Sys Req", "", "", "F11", "F12", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "F13", "F14", "F15", "F16",
    "F17", "F18", "F19", "F20", "F21", "F22", "F23", "F24", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    // extended
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "KP_Enter", "Control_R", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "KP_Divide", "", "Print", "Alt_R", "", "", "", "", "", "", "",
    "", "", "", "", "", "Num_Lock", "Break", "Home", "Up", "Prior", "", "Left", "", "Right", "", "End",
    "Down", "Next", "Insert", "Delete", "<00>", "", "Help", "", "", "", "", "Super_L", "Super_R", "Application", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    // zig fmt: on
};

pub fn getMousePosition() !struct { x: usize, y: usize } {
    var point: c.POINT = undefined;
    const result = c.GetCursorPos(&point);

    if (result == 1) {
        return .{
            .x = @intCast(point.x),
            .y = @intCast(point.y),
        };
    }

    return error.MouseError;
}
