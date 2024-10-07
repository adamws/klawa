const std = @import("std");

pub const Vec2 = extern struct {
    x: f64,
    y: f64,

    pub fn format(value: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, stream: anytype) !void {
        try stream.print("vec2({d}, {d})", .{ value.x, value.y });
    }
};

/// rotates the vector around the arbitrary center of rotation
pub fn rotate_around_center(vec: Vec2, center: Vec2, angle: f64) Vec2 {
    return .{
        .x = center.x + @cos(angle) * (vec.x - center.x) - @sin(angle) * (vec.y - center.y),
        .y = center.y + @sin(angle) * (vec.x - center.x) + @cos(angle) * (vec.y - center.y),
    };
}

pub fn round(value: f64, comptime places: u32) f64 {
    const factor: f64 = @floatCast(std.math.pow(f64, 10, places));
    return @round(value * factor) / factor;
}

