const clap = @import("clap");
const rl = @import("raylib");
const std = @import("std");
const fs = std.fs;

pub const AtlasError = error{
    InvalidImageDimensions,
};

// all dimensions in pixels

const Constants = struct {
    const keycap_1u_size: f32 = 64;
    const step_size: f32 = 16;
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

const keycap_sizes = getSizes(.horizontal, 1, 7) ++               // widths
                     getSizes(.vertical, 1, 2) ++                 // heights
                     [_]KeySize{.{ .width = 96, .height = 128 }}; // iso enter


fn getSizes(comptime direction: StitchDirection, comptime min: usize, comptime max: usize) [(max - min) * 4 + 1]KeySize {
    var result: [(max - min) * 4 + 1]KeySize = undefined;
    var current: f32 = min * Constants.keycap_1u_size;
    const max_dimension: f32 = max * Constants.keycap_1u_size;
    var i: usize = 0;
    while (current <= max_dimension) : (i += 1) {
        switch (direction) {
            .horizontal => {
                result[i].width = current;
                result[i].height = 1 * Constants.keycap_1u_size;
            },
            .vertical => {
                result[i].width = 1 * Constants.keycap_1u_size;
                result[i].height = current;
            }
        }
        current += Constants.step_size;
    }
    return result;
}

const atlas_width: f32 = sumWidths(&keycap_sizes);
const atlas_height: f32 = maxHeight(&keycap_sizes);

fn sumWidths(sizes: []const KeySize) f32 {
    var result: f32 = 0;
    for (sizes) |x| {
        result += x.width;
    }
    return result;
}

fn maxHeight(sizes: []const KeySize) f32 {
    var result: f32 = 0;
    for (sizes) |x| {
        if (x.height > result) result = x.height;
    }
    return result;
}

const atlas_positions = getPositions(&keycap_sizes);

const Coordinates = struct {
    x: f32,
    y: f32,
};

fn getPositions(sizes: []const KeySize) [keycap_sizes.len]Coordinates {
    var coordinates: [keycap_sizes.len]Coordinates = undefined;
    var current_x: f32 = 0;
    for (sizes, 0..) |x, i| {
        coordinates[i].x = current_x;
        coordinates[i].y = 0; // for default texture atlases we place images side by side
        current_x += x.width;
    }
    return coordinates;
}

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
    map_position: Coordinates,
    regions: BaseKeycapRegions,
) !void {
    std.debug.assert(!(size.width == 1 or size.height == 1));
    const stitch_direction = StitchDirection.determine(size);

    switch (stitch_direction) {
        .horizontal => try stitchHorizontally(
            result_image,
            source_image,
            size.width,
            map_position,
            regions,
        ),
        .vertical => try stitchVertically(
            result_image,
            source_image,
            size.height,
            map_position,
            regions,
        ),
    }
}

fn stitchHorizontally(
    result_image: *rl.Image,
    source_image: rl.Image,
    target_width: f32,
    map_position: Coordinates,
    regions: BaseKeycapRegions,
) !void {
    var dst = regions.left.withPosition(map_position.x, map_position.y);

    // Copy left portion
    rl.imageDraw(result_image, source_image, regions.left.rect, dst.rect, rl.Color.white);
    dst.rect.x += dst.rect.width;

    // Fill middle
    const middle_width = target_width - (regions.left.rect.width + regions.right.rect.width);
    var x: f32 = 0;
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
    target_height: f32,
    map_position: Coordinates,
    regions: BaseKeycapRegions,
) !void {
    var dst = regions.top.withPosition(map_position.x, map_position.y);

    // Copy top portion
    rl.imageDraw(result_image, source_image, regions.top.rect, dst.rect, rl.Color.white);
    dst.rect.y += dst.rect.height;

    // Fill middle
    const middle_height = target_height - (regions.top.rect.height + regions.bottom.rect.height);
    var y: f32 = 0;
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

    var result_image = rl.genImageColor(atlas_width, atlas_height, rl.Color.blank);

    var current_x_pos: usize = 0;
    for (keycap_sizes[0..keycap_sizes.len - 1], atlas_positions[0..atlas_positions.len - 1]) |size, map_position| {
        std.debug.print("size {any}\n", .{size});
        try generateStandardKey(&result_image, keycap_image, size, map_position, regions);
        current_x_pos += @intFromFloat(size.width);
    }

    // iso enter handled separately
    {
        const src = regions.iso_enter;
        const dst = src.withPosition(@floatFromInt(current_x_pos), 0);
        rl.imageDraw(&result_image, keycap_image, src.rect, dst.rect, rl.Color.white);
    }

    _ = rl.exportImage(result_image, output_file_path);
    std.debug.print("Exit\n", .{});
}
