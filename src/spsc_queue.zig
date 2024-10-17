const atomic = @import("std").atomic;
const std = @import("std");

const Atomic = atomic.Value;
const AtomicOrder = std.builtin.AtomicOrder;

pub fn SpscQueue(comptime capacity: comptime_int, comptime T: type) type {
    return struct {
        read_index: Atomic(usize),
        padding: Padding = undefined, // force read_index and write_index to different cache lines
        write_index: Atomic(usize),
        data: [capacity]T,

        const Padding = [atomic.cache_line - @sizeOf(Atomic(usize))]u8;
        pub const Self = @This();

        pub fn init() Self {
            if (comptime capacity < 2) {
                @compileError("Queue capacity must be greater than 2");
            }
            return Self{
                .write_index = Atomic(usize).init(0),
                .read_index = Atomic(usize).init(0),
                .data = undefined,
            };
        }

        pub fn empty(self: *Self) bool {
            const read_index = self.read_index.load(AtomicOrder.acquire);
            const write_index = self.write_index.load(AtomicOrder.acquire);
            return read_index == write_index;
        }

        pub fn push(self: *Self, item: T) bool {
            // write_index only written from push thread
            const write = self.write_index.load(AtomicOrder.unordered);
            var next_write = write + 1;
            if (next_write == capacity) {
                // @branchHint(.unlikely); // wait for zig 0.14
                next_write = 0;
            }
            const read = self.read_index.load(AtomicOrder.acquire);
            if (next_write == read) {
                return false; // queue is full
            }
            self.data[write] = item;
            self.write_index.store(next_write, AtomicOrder.release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            // read_index only written from pop thread
            const current_read = self.read_index.load(AtomicOrder.unordered);
            const write = self.write_index.load(AtomicOrder.acquire);
            if (current_read == write) {
                return null; // queue is empty
            }
            const value = self.data[current_read];
            var next_read = current_read + 1;
            if (next_read == capacity) {
                // @branchHint(.unlikely); // wait for zig 0.14
                next_read = 0;
            }
            self.read_index.store(next_read, AtomicOrder.release);
            return value;
        }
    };
}

const expect = @import("std").testing.expect;
const builtin = @import("builtin");

test "producer consumer" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const ExampleType = struct {
        field1: usize,
        field2: [32]u8,
    };
    const capacity = 16;

    const TestQueue = SpscQueue(capacity, ExampleType);

    const Producer = struct {
        pub fn run(queue: *TestQueue) !void {
            var i: u16 = 0;
            while (i != std.math.maxInt(u16)) {
                const data = ExampleType{ .field1 = @intCast(i), .field2 = .{1} ** 32 };
                while (!queue.push(data)) : ({
                    std.debug.print("Consumer outpaced, try again\n", .{});
                    std.time.sleep(10 * std.time.ns_per_ms);
                }) {}
                std.debug.print("Pushed: {d}\n", .{i});
                i = i +% 1;
            }
        }
    };

    const Consumer = struct {
        pub fn run(queue: *TestQueue) !void {
            while (true) {
                if (queue.pop()) |e| {
                    std.debug.print("Consumed: {d}\n", .{e.field1});
                    if (e.field1 + 1 == std.math.maxInt(u16)) {
                        break;
                    }
                }
            }
        }
    };

    var queue = TestQueue.init();
    try expect(queue.empty() == true);

    const producer = try std.Thread.spawn(.{}, Producer.run, .{&queue});
    const consumer = try std.Thread.spawn(.{}, Consumer.run, .{&queue});

    producer.join();
    consumer.join();

    try expect(queue.empty() == true);
}
