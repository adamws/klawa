const std = @import("std");
const fs = std.fs;
const ini = @import("ini.zig");

pub const ConfigData = struct {
    typing_font_size: i32 = 120,
    layout_path: []const u8 = "", // absolute or realative to config file
};

pub const AppConfg = struct {
    allocator: std.mem.Allocator,
    data: ConfigData,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !AppConfg {
        var config: ConfigData = std.mem.zeroInit(ConfigData, .{});

        if (fs.cwd().openFile(path, .{ .mode = .read_only })) |file| {
            defer file.close();

            var parser = ini.parse(allocator, file.reader(), "#;");
            defer parser.deinit();

            const config_fields = std.meta.fields(ConfigData);

            while (try parser.next()) |record| {
                switch (record) {
                    .section => |heading| {
                        // sections are not supported yet
                        std.debug.print("[{s}]\n", .{heading});
                    },
                    .property => |kv| {
                        std.debug.print("{s} = {s}\n", .{ kv.key, kv.value });
                        inline for (config_fields) |field| {
                            if (std.mem.eql(u8, field.name, kv.key)) {
                                switch (@typeInfo(field.type)) {
                                    .Int => {
                                        // TODO: only decimal values are handled now, could
                                        // implement automatic detection and handling based on
                                        // prefix
                                        @field(config, field.name) = try std.fmt.parseInt(i32, kv.value, 10);
                                    },
                                    .Pointer => {
                                        @field(config, field.name) = try allocator.dupe(u8, kv.value);
                                    },
                                    else => |t| {
                                        std.debug.print("other value types not handled yet, got {}\n", .{t});
                                        return error.UnsupportedConfigFieldType;
                                    },
                                }
                            }
                        }
                    },
                    .enumeration => |value| std.debug.print("{s}\n", .{value}),
                }
            }
        } else |err| switch (err) {
            error.FileNotFound => std.debug.print("config not found, using default\n", .{}),
            else => return err,
        }

        return .{
            .allocator = allocator,
            .data = config,
        };
    }

    pub fn deinit(self: *AppConfg) void {
        const config_fields = std.meta.fields(ConfigData);

        inline for (config_fields) |field| {
            switch (@typeInfo(field.type)) {
                .Pointer => self.allocator.free(@field(self.data, field.name)),
                else => {},
            }
        }

        self.* = undefined;
    }
};
