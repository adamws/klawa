const std = @import("std");
const fs = std.fs;
const io = std.io;

/// An entry in a ini file. Each line that contains non-whitespace text can
/// be categorized into a record type.
pub const Record = union(enum) {
    /// A section heading enclosed in `[` and `]`. The brackets are not included.
    section: []const u8,

    /// A line that contains a key-value pair separated by `=`.
    /// Both key and value have the excess whitespace trimmed.
    /// Both key and value allow escaping with C string syntax.
    property: KeyValue,

    /// A line that is either escaped as a C string or contains no `=`
    enumeration: []const u8,
};

pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub fn ConfigManager(comptime ConfigType: type) type {
    return struct {
        const Self = @This();

        const ConfigTypeFields = std.meta.FieldEnum(ConfigType);
        const ChangeSet = std.enums.EnumSet(ConfigTypeFields);

        const config_fields = std.meta.fields(ConfigType);

        const comment_characters = "#;";
        const whitespace = " \r\t\x00";

        allocator: std.mem.Allocator,
        data: ConfigType = .{},

        comptime {
            // TODO: assert that ConfigType has only members of supported types
            // (check parse function)
        }

        pub fn load(self: *Self, reader: io.AnyReader) !ChangeSet {
            std.debug.print("Reloading config\n", .{});
            var tmp: ConfigType = .{};

            var changed_fields = ChangeSet.initEmpty();

            if (self.parse(reader, &tmp)) {
                inline for (config_fields) |field| {
                    const old = @field(self.data, field.name);
                    const new = @field(tmp, field.name);

                    var change_found = false;
                    switch (@typeInfo(field.type)) {
                        .Bool, .Int, .Float => change_found = old != new,
                        .Pointer => |ptr| change_found = !std.mem.eql(ptr.child, old, new),
                        else => return error.UnsupportedConfigFieldType,
                    }
                    if (change_found) {
                        std.debug.print("Change of {s}: {any} -> {any}\n", .{field.name, old, new});
                        changed_fields.insert(@field(ConfigTypeFields, field.name));
                    }
                }

                if (changed_fields.count() != 0) {
                    freeConfig(self.allocator, &self.data);
                    self.data = tmp;
                } else {
                    freeConfig(self.allocator, &tmp);
                }

            } else |err| {
                std.debug.print("error: {}\n", .{err});
                std.debug.print("parsing config failed, reload aborted\n", .{});
                return error.ConfigParseError;
            }

            return changed_fields;
        }

        pub fn loadFromFile(self: *Self, file_path: []const u8) !ChangeSet {
            if (fs.cwd().openFile(file_path, .{ .mode = .read_only })) |file| {
                defer file.close();
                return self.load(file.reader().any());
            } else |err| switch (err) {
                error.FileNotFound => return error.ConfigNotFound,
                else => return err,
            }
        }

        fn parse(self: *Self, reader: io.AnyReader, data: *ConfigType) !void {
            var line_buffer = std.ArrayList(u8).init(self.allocator);
            defer line_buffer.deinit();

            // TODO: this could be smarter because we know numer and names of possible entries
            // so creating hash map should not be necessary (see StaticStringMap)
            var values = std.StringArrayHashMap(std.ArrayListUnmanaged(u8)).init(self.allocator);
            defer {
                var iter = values.iterator();
                while (iter.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    entry.value_ptr.*.deinit(self.allocator);
                }
                values.deinit();
            }

            while (try next(reader, &line_buffer)) |record| {
                switch (record) {
                    .section => |heading| {
                        // sections are not supported yet
                        std.debug.print("[{s}]\n", .{heading});
                    },
                    .property => |kv| {
                        if (!values.contains(kv.key)) {
                            std.debug.print("{s} = {s}\n", .{ kv.key, kv.value });
                            const map_key = try self.allocator.dupe(u8, kv.key);
                            const value_buffer = try self.allocator.alloc(u8, 4096);
                            var map_value = std.ArrayListUnmanaged(u8).initBuffer(value_buffer);
                            map_value.appendSliceAssumeCapacity(kv.value);

                            try values.put(map_key, map_value);
                        } else {
                            std.debug.print("Found duplicate of {s}, ignoring\n", .{ kv.key });
                        }
                    },
                    .enumeration => |value| {
                        var last_entry = values.pop();
                        last_entry.value.appendSliceAssumeCapacity(value);
                        try values.put(last_entry.key, last_entry.value);
                    },
                }
            }

            var iter = values.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const value = entry.value_ptr.*.items;
                std.debug.print("{s}: {s}\n", .{key, value});

                inline for (config_fields) |field| {
                    if (std.mem.eql(u8, field.name, key)) {
                        switch (@typeInfo(field.type)) {
                            .Bool => {
                                @field(data, field.name) = try parseBool(value);
                            },
                            .Int => {
                                @field(data, field.name) = try std.fmt.parseInt(field.type, value, 0);
                            },
                            .Float => {
                                @field(data, field.name) = try std.fmt.parseFloat(field.type, value);
                            },
                            .Pointer => {
                                if (std.meta.sentinel(field.type)) |sentinel| {
                                    const new_buf = try self.allocator.allocSentinel(u8, value.len, sentinel);
                                    @memcpy(new_buf, value);
                                    @field(data, field.name) = new_buf;
                                } else {
                                    @field(data, field.name) = try self.allocator.dupe(u8, value);
                                }
                            },
                            else => |t| {
                                std.debug.print("other value types not handled yet, got {}\n", .{t});
                                return error.UnsupportedConfigFieldType;
                            },
                        }
                    }
                }
            }
        }

        fn next(reader: io.AnyReader, line_buffer: *std.ArrayList(u8)) !?Record {
            while (true) {
                reader.readUntilDelimiterArrayList(line_buffer, '\n', 4096) catch |err| switch (err) {
                    error.EndOfStream => {
                        if (line_buffer.items.len == 0)
                            return null;
                    },
                    else => |e| return e,
                };

                var line: []const u8 = line_buffer.items;
                var last_index: usize = 0;

                // handle comments and escaping
                while (last_index < line.len) {
                    if (std.mem.indexOfAnyPos(u8, line, last_index, comment_characters)) |index| {
                        // escape character if needed, then skip it (it's not a comment)
                        if (index > 0) {
                            const previous_index = index - 1;
                            const previous_char = line[previous_index];

                            if (previous_char == '\\') {
                                _ = line_buffer.orderedRemove(previous_index);
                                line = line_buffer.items;

                                last_index = index + 1;
                                continue;
                            }
                        }
                        line = std.mem.trim(u8, line[0..index], whitespace);
                    } else {
                        line = std.mem.trim(u8, line, whitespace);
                    }
                    break;
                }

                if (line.len == 0)
                    continue;

                if (std.mem.startsWith(u8, line, "[") and std.mem.endsWith(u8, line, "]")) {
                    return Record{ .section = line[1 .. line.len - 1] };
                }

                if (std.mem.indexOfScalar(u8, line, '=')) |index| {
                    return Record{
                        .property = KeyValue{
                            // note: the key *might* replace the '=' in the slice with 0!
                            .key = std.mem.trim(u8, line[0..index], whitespace),
                            .value = std.mem.trim(u8, line[index + 1 ..], whitespace),
                        },
                    };
                }

                return Record{ .enumeration = line };
            }
        }

        pub fn deinit(self: *Self) void {
            freeConfig(self.allocator, &self.data);
            self.* = undefined;
        }

        fn freeConfig(allocator: std.mem.Allocator, data: *ConfigType) void {
            inline for (config_fields) |field| {
                switch (@typeInfo(field.type)) {
                    .Pointer => {
                        // must free non-default pointer values
                        const f = @field(data, field.name);
                        const default = @as(*align(1) const field.type, @ptrCast(field.default_value.?)).*;
                        if (default.ptr != f.ptr) {
                            allocator.free(f);
                        }
                    },
                    else => {},
                }
            }
        }

    };
}

pub fn configManager(comptime ConfigType: type, allocator: std.mem.Allocator) ConfigManager(ConfigType) {
    return ConfigManager(ConfigType){ .allocator = allocator };
}

pub const ParseBoolError = error{
    /// The input was empty or contained an invalid character
    InvalidCharacter,
};

fn parseBool(buf: []const u8) ParseBoolError!bool {
    inline for (.{
        .{ .s = "true", .r = true },
        .{ .s = "1", .r = true },
        .{ .s = "false", .r = false },
        .{ .s = "0", .r = false },
    }) |tc| {
        if (std.ascii.eqlIgnoreCase(buf, tc.s)) {
            return tc.r;
        }
    }
    return ParseBoolError.InvalidCharacter;
}

const testing = @import("std").testing;

test "config load and change" {

    const TestConfigData = struct {
        pointer_field: []const u8 = "default value",
        sentinel_pointer_field: [:0]const u8 = "terminated",
        numeric_field: i32 = -1,
        unsigned_numeric_field: u32 = 0x55,
    };

    const cases = [_]struct {
        start_data: []const u8,
        expected1: TestConfigData,
        update_data: []const u8,
        expected2: TestConfigData,
        err: ?anyerror = null,
    }{
        // TODO: add more tests, include some negative cases
        .{
            .start_data =
            \\pointer_field = testvalue # comment
            \\numeric_field = 55 ; another comment
            \\not_existing_field = something ; ignored
            ,
            .expected1 = .{
                .pointer_field = "testvalue",
                .sentinel_pointer_field = "terminated",
                .numeric_field = 55,
                .unsigned_numeric_field = 0x55,
            },
            .update_data =
            \\[ignored_section]
            \\sentinel_pointer_field = newvalue # comment
            \\unsigned_numeric_field = 0
            \\
            ,
            .expected2 = .{
                .pointer_field = "default value",
                .sentinel_pointer_field = "newvalue",
                .numeric_field = -1,
                .unsigned_numeric_field = 0,
            },
        },
    };

    const allocator = std.testing.allocator;

    for (cases) |case| {
        var stream = std.io.fixedBufferStream(case.start_data);
        const reader = stream.reader();

        var app_config = configManager(TestConfigData, allocator);
        defer app_config.deinit();

        _ = try app_config.load(reader.any());
        try testing.expectEqualDeep(case.expected1, app_config.data);

        var stream1 = std.io.fixedBufferStream(case.update_data);
        const reader1 = stream1.reader();

        const change = try app_config.load(reader1.any());
        try testing.expect(change.contains(.pointer_field));
        try testing.expect(change.contains(.sentinel_pointer_field));
        try testing.expect(change.contains(.numeric_field));
        try testing.expect(change.contains(.unsigned_numeric_field));
        try testing.expectEqualDeep(case.expected2, app_config.data);
    }
}

test "config multiline value" {
    const TestConfigData = struct {
        multiline_field: []const u8 = "default value",
        numeric_field: i32 = -1,
    };

    const allocator = std.testing.allocator;
    const data =
        \\multiline_field = 0 0,  64 0,  128 0,
        \\                  0 64, 96 64, 160 64,
        \\numeric_field = 10
        ;
    const expected = TestConfigData{
        .multiline_field = "0 0,  64 0,  128 0,0 64, 96 64, 160 64,",
        .numeric_field = 10
    };

    var stream = std.io.fixedBufferStream(data);
    const reader = stream.reader();

    var app_config = configManager(TestConfigData, allocator);
    defer app_config.deinit();

    _ = try app_config.load(reader.any());
    try testing.expectEqualDeep(expected, app_config.data);

    std.debug.print("{s}\n", .{app_config.data.multiline_field});
}

