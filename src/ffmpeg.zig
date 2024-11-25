const std = @import("std");
const process = std.process;
const Child = process.Child;
const File = std.fs.File;

const builtin = @import("builtin");

pub const Ffmpeg = struct {
    child: Child,

    pub fn spawn(
        width: usize,
        height: usize,
        output: []const u8,
        allocator: std.mem.Allocator,
    ) !Ffmpeg {
        const resolution = try std.fmt.allocPrint(allocator, "{d}x{d}", .{ width, height });
        defer allocator.free(resolution);
        const exec_name: []const u8 = switch (builtin.target.os.tag) {
            .linux => "ffmpeg",
            .windows => "ffmpeg.exe",
            else => @compileError("unsupported platform"),
        };
        const args = [_][]const u8{
            exec_name,    "-y",
            "-f",         "rawvideo",
            "-framerate", "60",
            "-s",         resolution,
            "-pix_fmt",   "rgba",
            "-i",         "-",
            "-vf",        "vflip", // TODO: compare what's better, vflip here or copy to pipe in
                                   // correct line order
            "-c:v",       "libvpx-vp9",
            output,
        };

        var ffmpeg = Child.init(&args, allocator);
        ffmpeg.stdout_behavior = .Inherit;
        ffmpeg.stdin_behavior = .Pipe;

        try ffmpeg.spawn();

        return .{ .child = ffmpeg };
    }

    pub fn write(self: *Ffmpeg, bytes: []const u8) !void {
        try self.child.stdin.?.writeAll(bytes);
    }

    pub fn wait(self: *Ffmpeg) !void {
        self.child.stdin.?.close();
        self.child.stdin = null;

        const term = try self.child.wait();

        switch (term) {
            .Exited => |code| {
                std.debug.print("ffmpeg exited with '{d}'\n", .{code});
            },
            .Signal, .Stopped, .Unknown => |code| {
                std.debug.print("ffmpeg stopped with '{d}'\n", .{code});
            },
        }
    }
};
