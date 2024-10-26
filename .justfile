event_file := "events.bin"

run:
  zig build run

run-record:
  rm events.txt
  zig build run -- --record {{event_file}}

run-replay:
  zig build run -- --replay {{event_file}}

run-replay-loop:
  zig build run -- --replay {{event_file}} --replay-loop

test-kle:
  zig test src/kle.zig

test-queue:
  zig test src/spsc_queue.zig
