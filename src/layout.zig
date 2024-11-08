const std = @import("std");
const enums = std.enums;

pub const Layout = enum {
    @"60_abnt2",
    @"60_ansi",
    @"60_ansi_arrow",
    @"60_ansi_tsangan",
    @"60_ansi_wkl",
    @"60_hhkb",
    @"60_iso",
    @"60_iso_arrow",
    @"60_iso_tsangan",
    @"60_iso_wkl",
    @"60_jis",
    @"60_tsangan_hhkb",
    @"64_ansi",
    @"64_iso",
    @"65_ansi",
    @"65_ansi_blocker",
    @"65_ansi_blocker_tsangan",
    @"65_iso",
    @"65_iso_blocker",
    @"65_iso_blocker_tsangan",
    @"66_ansi",
    @"66_iso",
    @"68_ansi",
    @"68_iso",
    @"75_ansi",
    @"75_iso",
    @"96_ansi",
    @"96_iso",
    alice,
    ergodox,
    fullsize_ansi,
    fullsize_extended_ansi,
    fullsize_extended_iso,
    fullsize_extended_jis,
    fullsize_iso,
    fullsize_jis,
    ortho_3x10,
    ortho_4x10,
    ortho_4x12,
    ortho_4x16,
    ortho_5x10,
    ortho_5x12,
    ortho_5x13,
    ortho_5x14,
    ortho_5x15,
    ortho_6x13,
    planck_mit,
    split_3x5_3,
    split_3x6_3,
    tkl_ansi,
    tkl_ansi_tsangan,
    tkl_ansi_wkl,
    tkl_f13_ansi,
    tkl_f13_ansi_tsangan,
    tkl_f13_ansi_wkl,
    tkl_f13_iso,
    tkl_f13_iso_tsangan,
    tkl_f13_iso_wkl,
    tkl_f13_jis,
    tkl_iso,
    tkl_iso_tsangan,
    tkl_iso_wkl,
    tkl_jis,
    tkl_nofrow_ansi,
    tkl_nofrow_iso,

    const Self = @This();
    const DataType = []const u8;
    const data = initializeDataArray(DataType);

    pub fn getData(self: Layout) DataType {
        return data[@intFromEnum(self)];
    }

    pub fn fromString(value: []const u8) ?Layout {
        return std.meta.stringToEnum(Layout, value);
    }

    fn initializeDataArray(
        comptime Data: type,
    ) [enums.directEnumArrayLen(Self, 0)]Data {
        const len = comptime enums.directEnumArrayLen(Self, 0);
        var result: [len]Data =  undefined;
        inline for (@typeInfo(Self).Enum.fields) |enum_field| {
            const layout_data = @embedFile(std.fmt.comptimePrint("resources/layouts/{s}.json", .{enum_field.name}));
            const enum_value = @field(Self, enum_field.name);
            const index = @as(usize, @intCast(@intFromEnum(enum_value)));
            result[index] = layout_data;
        }
        return result;
    }

};

const testing = @import("std").testing;

test "test layout embeds" {
    inline for (std.meta.fields(Layout)) |f| {
        const expected = @embedFile(std.fmt.comptimePrint("resources/layouts/{s}.json", .{f.name}));

        const layout = try std.meta.intToEnum(Layout, f.value);
        const actual = layout.getData();

        try testing.expectEqual(expected, actual);
    }
}
