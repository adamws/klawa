run:
  zig build run

run-record:
  rm events.txt
  zig build run -- --record events.txt

run-replay:
  zig build run -- --replay events.txt

test-kle:
  zig test src/kle.zig

test-queue:
  zig test src/spsc_queue.zig
