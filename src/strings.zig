const std = @import("std");


pub fn CountingStringRingBuffer(comptime capacity: comptime_int, comptime max_string_len: comptime_int) type {
    return struct {
        write_index: Index = 0,
        strings: [capacity][max_string_len]u8 = .{.{0} ** max_string_len } ** capacity,
        lengths: [capacity]u8 = .{0} ** capacity,
        repeats: [capacity]usize = .{0} ** capacity,

        const Self = @This();
        const Codepoint = i32;
        const RepeatedStrig = struct{ repeat: usize, string: []const u8 };

        comptime {
            std.debug.assert(std.math.isPowerOfTwo(capacity));
        }
        const IndexBits = std.math.log2_int(usize, capacity);
        const Index = std.meta.Int(.unsigned, IndexBits);

        pub fn push(self: *Self, string: []const u8) !void {
            if (string.len > max_string_len) return error.StringTooLong;
            if (string.len == 0) return;

            const last_index = self.write_index -% 1;
            const last_string = self.strings[last_index][0..self.lengths[last_index]];

            if (std.mem.eql(u8, last_string, string)) {
                self.repeats[last_index] +|= 1;
            } else {
                self.repeats[self.write_index] = 1;
                self.lengths[self.write_index] = @intCast(string.len);
                std.mem.copyForwards(u8, &self.strings[self.write_index], string);

                self.write_index = self.write_index +% 1;
            }
        }

        pub fn backspace(self: *Self) void {
            const last_index = self.write_index -% 1;
            const last_repeats = self.repeats[last_index];

            if (last_repeats > 1) {
                self.repeats[last_index] -= 1;
            } else {
                self.lengths[last_index] = 0;
                self.repeats[last_index] = 0;
                self.write_index = last_index;
            }
        }

        pub const ReverseIterator = struct {
            queue: *Self,
            count: Index,

            pub fn next(it: *ReverseIterator) ?RepeatedStrig {
                it.count = it.count -% 1;
                if (it.count == it.queue.write_index) return null;

                const length: usize = @intCast(it.queue.lengths[it.count]);
                if (length == 0) return null;

                return .{
                   .repeat = it.queue.repeats[it.count],
                   .string = it.queue.strings[it.count][0..it.queue.lengths[it.count]],
                };
            }
        };

        pub fn reverse_iterator(self: *Self) ReverseIterator {
            return ReverseIterator{
                .queue = self,
                .count = self.write_index,
            };
        }
    };
}

const testing = std.testing;

test "counting string buffer" {

    const Buffer = CountingStringRingBuffer(4, 3);
    const RepeatedStrig = Buffer.RepeatedStrig;

    var buffer = Buffer{};

    try buffer.push("abc");
    try buffer.push("def");
    try buffer.push("def");
    try buffer.push(""); // empty strings are ignored

    var it = buffer.reverse_iterator();
    try testing.expectEqualDeep(RepeatedStrig{ .repeat = 2, .string = "def" }, it.next().?);
    try testing.expectEqualDeep(RepeatedStrig{ .repeat = 1, .string = "abc" }, it.next().?);
    try testing.expect(it.next() == null);

    try buffer.push("ghi");
    buffer.backspace();
    try buffer.push("abc");
    try buffer.push("jkl");

    it = buffer.reverse_iterator();
    try testing.expectEqualDeep(RepeatedStrig{ .repeat = 1, .string = "jkl" }, it.next().?);
    try testing.expectEqualDeep(RepeatedStrig{ .repeat = 1, .string = "abc" }, it.next().?);
    try testing.expectEqualDeep(RepeatedStrig{ .repeat = 2, .string = "def" }, it.next().?);
    try testing.expect(it.next() == null);

    buffer.backspace();
    buffer.backspace();
    try buffer.push("abc");

    it = buffer.reverse_iterator();
    try testing.expectEqualDeep(RepeatedStrig{ .repeat = 1, .string = "abc" }, it.next().?);
    try testing.expectEqualDeep(RepeatedStrig{ .repeat = 2, .string = "def" }, it.next().?);
    try testing.expectEqualDeep(RepeatedStrig{ .repeat = 1, .string = "abc" }, it.next().?);
    try testing.expect(it.next() == null);
}
