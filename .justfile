run:
  zig build run

test-kle:
  zig test src/kle.zig

test-queue:
  zig test src/spsc_queue.zig
