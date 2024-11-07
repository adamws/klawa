const clap = @import("clap");
const rl = @import("raylib");
const std = @import("std");
const fs = std.fs;

pub const AtlasError = error{
    UnsupportedKeycapSize,
    InvalidImageDimensions,
};

// all dimensions in pixels

const Constants = struct {
    const keycap_1u_size: f32 = 64;
    const step_size: f32 = 16;
    const atlas_width: f32 = 7 * keycap_1u_size;
    const atlas_height: f32 = 4 * atlas_width + 64 + 96;
};

const KeySize = struct {
    width: f32,
    height: f32,
};

const StitchDirection = enum {
    horizontal,
    vertical,

    fn determine(key_size: KeySize) StitchDirection {
        return if (key_size.height == Constants.keycap_1u_size) .horizontal else .vertical;
    }
};

const ImageRegion = struct {
    const Self = @This();
    rect: rl.Rectangle,

    fn init(x: f32, y: f32, width: f32, height: f32) Self {
        return .{
            .rect = .{
                .x = x,
                .y = y,
                .width = width,
                .height = height,
            },
        };
    }

    fn withPosition(self: Self, x: f32, y: f32) Self {
        var new = self;
        new.rect.x = x;
        new.rect.y = y;
        return new;
    }
};

const BaseKeycapRegions = struct {
    const Self = @This();

    left: ImageRegion,
    right: ImageRegion,
    top: ImageRegion,
    bottom: ImageRegion,
    middle1px_vertical: ImageRegion,
    middle1px_horizontal: ImageRegion,
    iso_enter: ImageRegion,

    fn init(width: f32, height: f32) Self {
        const half_width = width / 2;
        const half_height = height / 2;

        return .{
            .left = ImageRegion.init(0, 0, half_width, height),
            .right = ImageRegion.init(half_width, 0, half_width, height),
            .top = ImageRegion.init(0, 0, width, half_height),
            .bottom = ImageRegion.init(0, half_height, width, half_height),
            .middle1px_vertical = ImageRegion.init(half_width, 0, 1, height),
            .middle1px_horizontal = ImageRegion.init(0, half_height, width, 1),
            .iso_enter = ImageRegion.init(64, 0, 96, 128),
        };
    }
};

fn generateStandardKey(
    result_image: *rl.Image,
    source_image: rl.Image,
    size: KeySize,
    current_y_pos: *usize,
    regions: BaseKeycapRegions,
) !void {
    const stitch_direction = StitchDirection.determine(size);

    const current_width: c_int = @intFromFloat(size.width);
    const current_height: c_int = @intFromFloat(size.height);

    switch (stitch_direction) {
        .horizontal => try stitchHorizontally(
            result_image,
            source_image,
            current_width,
            current_y_pos.*,
            regions,
        ),
        .vertical => try stitchVertically(
            result_image,
            source_image,
            current_height,
            current_y_pos.*,
            regions,
        ),
    }

    current_y_pos.* += @intCast(current_height);
}

fn stitchHorizontally(
    result_image: *rl.Image,
    source_image: rl.Image,
    current_width: c_int,
    y_pos: usize,
    regions: BaseKeycapRegions,
) !void {
    std.debug.print("curent width {any}\n", .{current_width});
    var dst = regions.left.withPosition(0, @floatFromInt(y_pos));

    // Copy left portion
    rl.imageDraw(result_image, source_image, regions.left.rect, dst.rect, rl.Color.white);
    dst.rect.x += dst.rect.width;

    // Fill middle
    const middle_width = current_width - @as(c_int, @intFromFloat(regions.left.rect.width + regions.right.rect.width));
    var x: c_int = 0;
    while (x < middle_width) : (x += 1) {
        var middle_dst = dst.rect;
        middle_dst.width = 1;
        rl.imageDraw(result_image, source_image, regions.middle1px_vertical.rect, middle_dst, rl.Color.white);
        dst.rect.x += 1;
    }

    // Copy right portion
    rl.imageDraw(result_image, source_image, regions.right.rect, dst.rect, rl.Color.white);
}

fn stitchVertically(
    result_image: *rl.Image,
    source_image: rl.Image,
    current_height: c_int,
    y_pos: usize,
    regions: BaseKeycapRegions,
) !void {
    var dst = regions.top.withPosition(0, @floatFromInt(y_pos));

    // Copy top portion
    rl.imageDraw(result_image, source_image, regions.top.rect, dst.rect, rl.Color.white);
    dst.rect.y += dst.rect.height;

    // Fill middle
    const middle_height = current_height - @as(c_int, @intFromFloat(regions.top.rect.height + regions.bottom.rect.height));
    var y: c_int = 0;
    while (y < middle_height) : (y += 1) {
        var middle_dst = dst.rect;
        middle_dst.height = 1;
        rl.imageDraw(result_image, source_image, regions.middle1px_horizontal.rect, middle_dst, rl.Color.white);
        dst.rect.y += 1;
    }

    // Copy bottom portion
    rl.imageDraw(result_image, source_image, regions.bottom.rect, dst.rect, rl.Color.white);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\    --keycap <str>     Path to keycap theme.
        \\    --output <str>     Path to result atlas file.
        \\-h, --help             Display this help and exit.
        \\
    );

    var res = try clap.parse(clap.Help, &params, clap.parsers.default, .{ .allocator = allocator });
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{
            .spacing_between_parameters = 0,
        });
    }

    const keycap_file_path = if (res.args.keycap) |val| blk: {
        break :blk try allocator.dupeZ(u8, val);
    } else {
        return error.MissingArgument;
    };
    defer allocator.free(keycap_file_path);
    const output_file_path = if (res.args.output) |val| blk: {
        break :blk try allocator.dupeZ(u8, val);
    } else {
        return error.MissingArgument;
    };
    defer allocator.free(output_file_path);

    const keycap_image = rl.loadImage(keycap_file_path);
    defer rl.unloadImage(keycap_image);

    if (keycap_image.width != @as(c_int, @intFromFloat(Constants.keycap_1u_size * 2.5)) and
        keycap_image.height != @as(c_int, @intFromFloat(Constants.keycap_1u_size * 2)))
    {
        return AtlasError.InvalidImageDimensions;
    }

    const regions = BaseKeycapRegions.init(Constants.keycap_1u_size, Constants.keycap_1u_size);

    var result_image = rl.genImageColor(Constants.atlas_width, Constants.atlas_height, rl.Color.blank);
    var current_y_pos: usize = 0;

    // horizontal keys from 1u to 7u with 0.25u increment
    {
        var current_size = Constants.keycap_1u_size;
        while (current_size <= Constants.atlas_width) {
            const size = KeySize{ .width = current_size, .height = Constants.keycap_1u_size };
            std.debug.print("size {any}\n", .{size});
            try generateStandardKey(&result_image, keycap_image, size, &current_y_pos, regions);
            current_size += Constants.step_size;
        }
    }

    // vertical keys (1.5u and 2u for now)
    {
        const heights = [_]f32{ 1.5, 2 };
        for (heights) |h| {
            const size = KeySize{ .width = Constants.keycap_1u_size, .height = h * Constants.keycap_1u_size };
            try generateStandardKey(&result_image, keycap_image, size, &current_y_pos, regions);
        }
    }

    // iso enter
    {
        const src = regions.iso_enter;
        const dst = src.withPosition(0, @floatFromInt(current_y_pos));
        rl.imageDraw(&result_image, keycap_image, src.rect, dst.rect, rl.Color.white);
    }

    _ = rl.exportImage(result_image, output_file_path);
    std.debug.print("Exit\n", .{});
}
