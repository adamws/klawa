const std = @import("std");
const fs = std.fs;

const c = @cImport({
  @cInclude("windows.h");
});

const AppState = @import("main.zig").AppState;
const KeyData = @import("main.zig").KeyData;
const labels_lookup = @import("layout_labels.zig").labels_lookup;

pub var x11_thread_active: bool = false;
pub var run_x11_thread: bool = true;

var app_state_l: *AppState = undefined;
var hook: ?c.HHOOK = null;

fn keyEventToString(vk: u32, scan_code: u32, string: []u8) !void {
    var keyboard_state: [256]u8 = undefined;

    if (c.GetKeyboardState(&keyboard_state) == 0) {
        return error.KeyboardStateErr;
    }

    var buffer: [16]u16 = undefined;
    const len = c.ToUnicode(vk, scan_code, &keyboard_state, &buffer, buffer.len, 0);
    const buffer_slice = buffer[0..@as(usize, @intCast(len))];

    _ = try std.unicode.utf16LeToUtf8(string, buffer_slice);
}

fn lowLevelKeyboardProc(nCode: c.INT, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.C) c.LRESULT {
    if (nCode == c.HC_ACTION) {
        const keyboard: *const c.KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @intCast(lParam)));

        app_state_l.updateKeyStates(keyboard.vkCode, wParam == c.WM_KEYDOWN);

        if (wParam == c.WM_KEYDOWN) {
            var key: KeyData = std.mem.zeroInit(KeyData, .{});

            key.keycode = @intCast(keyboard.vkCode);

            app_state_l.last_char_timestamp = std.time.timestamp();
            keyEventToString(keyboard.vkCode, keyboard.scanCode, &key.string) catch {};

            key.symbol = kbd_en_vscname[@as(usize, @intCast(keyboard.scanCode))].ptr;

            while (!app_state_l.keys.push(key)) : ({
                // this is unlikely scenario - normal typing would not be fast enough
                std.debug.print("Consumer outpaced, try again\n", .{});
                std.time.sleep(10 * std.time.ns_per_ms);
            }) {}
            std.debug.print("Produced: '{any}'\n", .{key});
        }
    }
    return c.CallNextHookEx(hook.?, nCode, wParam, lParam);
}

pub fn listener(app_state: *AppState, window_handle: *anyopaque, record_file: ?[]const u8) !void {
    _ = window_handle;
    _ = record_file;

    app_state_l = app_state;

    hook = c.SetWindowsHookExA(c.WH_KEYBOARD_LL, lowLevelKeyboardProc, null, 0).?;
    defer _ = c.UnhookWindowsHookEx(hook.?);

    var msg: c.MSG = undefined;
    while (c.GetMessageA(&msg, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageA(&msg);
    }
}

// uses events stored in file to reproduce them
// assumes that only expected event types are recorded
pub fn producer(app_state: *AppState, window_handle: *anyopaque, replay_file: []const u8, loop: bool) !void {
    _ = app_state;
    _ = window_handle;
    _ = replay_file;
    _ = loop;
}

// must match names used by X11:
const kbd_en_vscname = [_][]const u8 {
    // zig fmt: off
    "", "Escape", "", "", "", "", "", "", "", "", "", "", "", "", "BackSpace", "Tab",
    "", "", "", "", "", "", "", "", "", "", "", "", "Return", "Ctrl", "", "",
    "", "", "", "", "", "", "", "", "", "", "Shift", "", "", "", "", "",
    "", "", "", "", "", "", "Right Shift", "Num *", "Alt", "space", "Caps Lock", "F1", "F2", "F3", "F4", "F5",
    "F6", "F7", "F8", "F9", "F10", "Pause", "Scroll Lock", "Num 7", "Num 8", "Num 9", "Num -", "Num 4", "Num 5", "Num 6", "Num +", "Num 1",
    "Num 2", "Num 3", "Num 0", "Num Del", "Sys Req", "", "", "F11", "F12", "", "", "", "", "", "", "",
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
    "", "", "", "", "", "", "", "", "", "", "", "", "Num Enter", "Right Ctrl", "", "",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "", "Num /", "", "Prnt Scrn", "Right Alt", "", "", "", "", "", "", "",
    "", "", "", "", "", "Num ock", "Break", "Home", "Up", "Page Up", "", "eft", "", "Right", "", "End",
    "Down", "Page Down", "Insert", "Delete", "<00>", "", "Help", "", "", "", "", "Left Windows", "Right Windows", "Application", "", "",
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
