const std = @import("std");
const fs = std.fs;
const os = std.os;
const builtin = @import("builtin");


pub const Watch = switch (builtin.target.os.tag) {
    .linux => InotifyWatch,
    .windows => NullWatch, // file watch not supported yet
    else => @compileError("unsupported platform"),
};

const InotifyWatch = struct {
    const Self = @This();

    const Event = std.os.linux.inotify_event;
    const event_size = @sizeOf(Event);

    inotify_fd: i32 = -1,

    pub fn init(path: [:0]const u8) !Self {

        const inotify_fd: i32 = @intCast(os.linux.inotify_init1(std.os.linux.IN.NONBLOCK));
        _ = os.linux.inotify_add_watch(inotify_fd, path, 0x3);

        return .{
            .inotify_fd = inotify_fd,
        };
    }

    pub fn checkForChanges(self: Self) !bool {
        const notify = fs.File{ .handle = self.inotify_fd };
        var buffer: [1024]u8 = undefined;
        const bytes_read = try readInotifyEvents(&notify, &buffer);
        if (bytes_read > 0) {
            const event: *Event = @alignCast(@ptrCast(buffer[0..bytes_read]));
            if (event.mask & std.os.linux.IN.MODIFY != 0) {
                std.debug.print("modified\n", .{});
                return true;
            }
        }
        return false;
    }

    fn readInotifyEvents(file: *const fs.File, buffer: []u8) !usize {
        return file.read(buffer) catch |err| {
            switch (err) {
                error.WouldBlock => return 0,
                else => return err,
            }
        };
    }

    pub fn deinit(self: *Self) void {
        // inotify_rm_watch(fd: i32, wd: i32)
        self.* = undefined;
    }
};

const NullWatch = struct {
    const Self = @This();

    pub fn init(path: [:0]const u8) !Self {
        _ = path;
        return .{};
    }

    pub fn checkForChanges(self: Self) !bool {
        _ = self;
        return false;
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }
};
