const std = @import("std");
const json = std.json;

const DEFAULT_KEY_COLOR = "#cccccc";
const DEFAULT_TEXT_COLOR = "#000000";
const DEFAULT_TEXT_SIZE = 3;
const KEY_MAX_LABELS = 12;

// Map from serialized label position to normalized position,
// depending on the alignment flags.
const LABEL_MAP = [_][KEY_MAX_LABELS]i64 {
    // 0  1  2  3  4  5  6  7  8  9 10 11    // align flags
    .{ 0, 6, 2, 8, 9,11, 3, 5, 1, 4, 7,10 }, // 0 = no centering
    .{ 1, 7,-1,-1, 9,11, 4,-1,-1,-1,-1,10 }, // 1 = center x
    .{ 3,-1, 5,-1, 9,11,-1,-1, 4,-1,-1,10 }, // 2 = center y
    .{ 4,-1,-1,-1, 9,11,-1,-1,-1,-1,-1,10 }, // 3 = center x & y
    .{ 0, 6, 2, 8,10,-1, 3, 5, 1, 4, 7,-1 }, // 4 = center front (default)
    .{ 1, 7,-1,-1,10,-1, 4,-1,-1,-1,-1,-1 }, // 5 = center front & x
    .{ 3,-1, 5,-1,10,-1,-1,-1, 4,-1,-1,-1 }, // 6 = center front & y
    .{ 4,-1,-1,-1,10,-1,-1,-1,-1,-1,-1,-1 }, // 7 = center front & x & y
};

const Point = struct { x: f64, y: f64 };

fn rotate(origin: Point, point: Point, angle: f64) Point {
    const ox = origin.x;
    const oy = origin.y;
    const px = point.x;
    const py = point.y;
    const radians = std.math.rad_per_deg * angle;
    const qx = ox + @cos(radians) * (px - ox) - @sin(radians) * (py - oy);
    const qy = oy + @sin(radians) * (px - ox) + @cos(radians) * (py - oy);
    return .{ .x = qx, .y = qy };
}

pub const KeyDefault = struct {
    textColor: []const u8 = DEFAULT_TEXT_COLOR,
    textSize: i64 = DEFAULT_TEXT_SIZE,
};

pub const Key = struct {
    color: []const u8 = DEFAULT_KEY_COLOR,
    labels: [KEY_MAX_LABELS]?[]const u8 = .{null} ** KEY_MAX_LABELS,
    textColor: [KEY_MAX_LABELS]?[]const u8 = .{null} ** KEY_MAX_LABELS,
    textSize: [KEY_MAX_LABELS]?[]i64 = .{null} ** KEY_MAX_LABELS,
    default: KeyDefault = KeyDefault{},
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 1,
    height: f64 = 1,
    x2: f64 = 0,
    y2: f64 = 0,
    width2: f64 = 1,
    height2: f64 = 1,
    rotation_x: f64 = 0,
    rotation_y: f64 = 0,
    rotation_angle: f64 = 0,
    decal: bool = false,
    ghost: bool = false,
    stepped: bool = false,
    nub: bool = false,
    profile: []const u8 = "",
    sm: []const u8 = "",
    sb: []const u8 = "",
    st: []const u8 = "",

    pub fn jsonStringify(self: *const Key, jws: anytype) !void {
        const fields = std.meta.fields(Key);

        try jws.beginObject();
        inline for (fields) |field| {
            try jws.objectField(field.name);
            switch(@typeInfo(field.type)) {
                .Array => {
                    // array but without trailing nulls, empty [] if all nulls
                    const value = @field(self, field.name);
                    var i: usize = value.len;
                    while (i > 0) {
                        i -= 1;
                        if (value[i] != null) {
                            break;
                        }
                    }
                    const j = if (i == 0 and value[i] == null) 0 else i + 1;
                    try jws.write(value[0..j]);
                },
                .Float => {
                    // overwrite default json/stringify WriteStream's write
                    // function which formats strings in scientific notation
                    // (in zig 0.13.0), perhaps this will become unnecessary:
                    try jws.print("{d}", .{@field(self, field.name)});
                },
                else => {
                    try jws.write(@field(self, field.name));
                }
            }
        }
        try jws.endObject();
    }
};

pub const KeyboardMetadata = struct {
    author: []const u8 = "",
    backcolor: []const u8 = "#eeeeee",
    background: ?[]const u8 = null,
    name: []const u8 = "",
    notes: []const u8 = "",
    radii: []const u8 = "",
    switchBrand: []const u8 = "",
    switchMount: []const u8 = "",
    switchType: []const u8 = "",
};

pub const Keyboard = struct {
    meta: KeyboardMetadata = .{},
    keys: []Key,

    pub fn calculateBoundingBox(self: *const Keyboard) !struct { x: f64, y: f64, w: f64, h: f64 } {
        var max_x: f64 = 0;
        var max_y: f64 = 0;
        for (self.keys) |k| {
            const angle = k.rotation_angle;
            if (angle != 0) {
                const rot_origin = Point{ .x = k.rotation_x, .y = k.rotation_y };

                // when rotated, check each corner
                const x1 = k.x;
                const x2 = k.x + k.width;
                const y1 = k.y;
                const y2 = k.y + k.height;
                const corners = [4]Point {
                    .{ .x = x1, .y = y1 },
                    .{ .x = x2, .y = y1 },
                    .{ .x = x1, .y = y2 },
                    .{ .x = x2, .y = y2 },
                };

                for (corners) |p| {
                    const rotated = rotate(rot_origin, p, angle);
                    if (rotated.x >= max_x) max_x = rotated.x;
                    if (rotated.y >= max_y) max_y = rotated.y;
                }
            } else {
                //when not rotated, it is safe to check only bottom right corner:
                const x = k.x + k.width;
                const y = k.y + k.height;
                if (x >= max_x) max_x = x;
                if (y >= max_y) max_y = y;
            }
        }
        // note: always start at (0, 0).
        // we do not support layout shifting
        return .{ .x = 0, .y = 0, .w = max_x, .h = max_y };
    }
};

fn round(value: f64, comptime places: u32) f64 {
    const factor: f64 = @floatCast(std.math.pow(f64, 10, places));
    return @round(value * factor) / factor;
}

fn asf64(v: json.Value) !f64 {
    switch(v) {
        .integer => {
            return @floatFromInt(v.integer);
        },
        .float => {
            return v.float;
        },
        else => {
            return error.Unexpected;
        }
    }
}

fn reorder_items(comptime T: type, items: [KEY_MAX_LABELS]?T, _align: usize) [KEY_MAX_LABELS]?T {
    var ret: [KEY_MAX_LABELS]?T = .{null} ** KEY_MAX_LABELS;

    for (items, 0..) |item, index| {
        if (item != null) {
            const i: usize = @intCast(LABEL_MAP[_align][index]);
            ret[i] = item;
        }
    }
    return ret;
}

fn parseKle(kle: json.Value, arena: *std.heap.ArenaAllocator) !Keyboard {
    var keys = std.ArrayList(Key).init(arena.allocator());
    defer keys.deinit();

    var cluster: Point = .{ .x = 0, .y = 0};
    var _align: usize = 4;

    var current = Key{};

    switch (kle) {
        .array => {
            for (kle.array.items) |value| {
                switch(value) {
                    .object => {
                        return error.MetadataNotHandledYet;
                    },
                    .array => {
                        for (value.array.items, 0..) |key, index| {
                            switch(key) {
                                .string => {
                                    _ = index;

                                    var new_key = current;
                                    new_key.width2 = if (new_key.width2 == 0) current.width else current.width2;
                                    new_key.height2 = if (new_key.height2 == 0) current.height else current.height2;

                                    var iter = std.mem.split(u8, key.string, "\n");
                                    var label_count: usize = 0;
                                    while (iter.next()) |label| {
                                        if (label_count < KEY_MAX_LABELS) {
                                            new_key.labels[label_count] = if (label.len == 0) null else label;
                                        }
                                        label_count += 1;
                                    }

                                    new_key.labels = reorder_items([]const u8,new_key.labels, _align);
                                    new_key.textSize = reorder_items([]i64, new_key.textSize, _align);

                                    // TODO: cleanup_key(new_key)

                                    try keys.append(new_key);

                                    current.x = round(current.x + current.width, 6);
                                    current.width = 1;
                                    current.height = 1;
                                    current.x2 = 0;
                                    current.y2 = 0;
                                    current.width2 = 0;
                                    current.height2 = 0;
                                    current.nub = false;
                                    current.stepped = false;
                                    current.decal = false;
                                },
                                .object => {
                                    // TODO: raise when rotation on first key in row

                                    if (key.object.get("r")) |v| {
                                        current.rotation_angle = try asf64(v);
                                    }
                                    if (key.object.get("rx")) |v| {
                                        cluster.x = try asf64(v);
                                        current.x = cluster.x;
                                        current.y = cluster.y;
                                        current.rotation_x = current.x;
                                    }
                                    if (key.object.get("ry")) |v| {
                                        cluster.y = try asf64(v);
                                        current.x = cluster.x;
                                        current.y = cluster.y;
                                        current.rotation_y = current.y;
                                    }
                                    if (key.object.get("a")) |v| {
                                        _align = @intCast(v.integer);
                                    }
                                    if (key.object.get("f")) |v| {
                                        // text size not handled yet
                                        _ = v;
                                    }
                                    if (key.object.get("f2")) |v| {
                                        // text size not handled yet
                                        _ = v;
                                    }
                                    if (key.object.get("fa")) |v| {
                                        // text size not handled yet
                                        _ = v;
                                    }
                                    if (key.object.get("p")) |v| {
                                        current.profile = v.string;
                                    }
                                    if (key.object.get("c")) |v| {
                                        current.color = v.string;
                                    }
                                    if (key.object.get("t")) |v| {
                                        // text color not handled yet
                                        _ = v;
                                    }
                                    if (key.object.get("x")) |v| {
                                        current.x = round(current.x + try asf64(v), 6);
                                    }
                                    if (key.object.get("y")) |v| {
                                        current.y = round(current.y + try asf64(v), 6);
                                    }
                                    if (key.object.get("w")) |v| {
                                        const w = try asf64(v);
                                        current.width = w;
                                        current.width2 = w;
                                    }
                                    if (key.object.get("h")) |v| {
                                        const h = try asf64(v);
                                        current.height = h;
                                        current.height2 = h;
                                    }
                                    if (key.object.get("x2")) |v| {
                                        current.x2 = try asf64(v);
                                    }
                                    if (key.object.get("y2")) |v| {
                                        current.y2 = try asf64(v);
                                    }
                                    if (key.object.get("w2")) |v| {
                                        current.width2 = try asf64(v);
                                    }
                                    if (key.object.get("h2")) |v| {
                                        current.height2 = try asf64(v);
                                    }
                                    if (key.object.get("n")) |v| {
                                        current.nub = v.bool;
                                    }
                                    if (key.object.get("l")) |v| {
                                        current.stepped = v.bool;
                                    }
                                    if (key.object.get("d")) |v| {
                                        current.decal = v.bool;
                                    }
                                    if (key.object.get("g")) |v| {
                                        current.ghost = v.bool;
                                    }
                                    if (key.object.get("sm")) |v| {
                                        current.sm = v.string;
                                    }
                                    if (key.object.get("sb")) |v| {
                                        current.sb = v.string;
                                    }
                                    if (key.object.get("st")) |v| {
                                        current.sb = v.string;
                                    }
                                },
                                else => {
                                    return error.InvalidType;
                                }
                            }
                        }

                        // end of the row:
                        current.y = round(current.y + 1, 6);
                        current.x = current.rotation_x;
                    },
                    else => {
                        return error.InvalidType;
                    }
                }
            }
        },
        else => {
            return error.InvalidType;
        }
    }

    return Keyboard {
        .keys = try keys.toOwnedSlice()
    };
}

pub fn parseFromSlice(
    allocator: std.mem.Allocator,
    s: []const u8,
) !std.json.Parsed(Keyboard) {
    const kle = try json.parseFromSlice(json.Value, allocator, s, .{});
    const keyboard = try parseKle(kle.value, kle.arena);
    return .{
        .arena = kle.arena,
        .value = keyboard
    };
}

const expect = @import("std").testing.expect;

fn makeTestCase(comptime name: []const u8) type {
    return struct {
        test "parse kle layout" {
            const allocator = std.testing.allocator;

            const kle_str = @embedFile(std.fmt.comptimePrint("test_data/{s}.json", .{name}));
            const kle = try parseFromSlice(allocator, kle_str);
            defer kle.deinit();

            var out = std.ArrayList(u8).init(allocator);
            defer out.deinit();

            try json.stringify(kle.value, .{ .whitespace = .indent_2 }, out.writer());

            const reference = @embedFile(std.fmt.comptimePrint("test_data/{s}-internal.json", .{name}));
            try std.testing.expect(std.mem.eql(u8, out.items, reference));
        }

        test "calculate bounding box" {
            const allocator = std.testing.allocator;

            const kle_str = @embedFile(std.fmt.comptimePrint("test_data/{s}.json", .{name}));
            const kle = try parseFromSlice(allocator, kle_str);
            defer kle.deinit();

            const bbox = try kle.value.calculateBoundingBox();
            const width: i64 = @intFromFloat(bbox.w * 64);
            const height: i64 = @intFromFloat(bbox.h * 64);

            if (std.mem.eql(u8, name, "ansi-104")) {
                try expect(width == 1440);
                try expect(height == 416);
            } else if (std.mem.eql(u8, name, "atreus")) {
                try expect(width == 812);
                try expect(height == 345);
            } else {
                unreachable;
            }
        }
    };
}

const testParams = [_][]const u8 {"ansi-104", "atreus"};

test {
    inline for (testParams) |i| std.testing.refAllDecls(makeTestCase(i));
}

