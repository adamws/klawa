event_file := "events.bin"
tracy_path := "/home/aws/git/tracy"

run:
  zig build run

run-tracy:
  zig build run -Dtracy={{tracy_path}} -Dtracy-allocation -Dtracy-callstack

run-record:
  rm -f {{event_file}}
  zig build run -- --record {{event_file}}

run-replay:
  zig build run -- --replay {{event_file}}

run-replay-loop:
  zig build run -- --replay {{event_file}} --replay-loop

run-replay-render:
  rm -rf frames.raw
  zig build run -- --replay {{event_file}} --render frames.raw
  mpv --loop output.webm

run-replay-render-tracy:
  rm -rf frames.raw
  zig build run -Dtracy={{tracy_path}} -Dtracy-allocation -Dtracy-callstack -- --replay {{event_file}} --render frames.raw

test-kle:
  zig test src/kle.zig

test-queue:
  zig test src/spsc_queue.zig

pytest:
  cd tests && . .env/bin/activate && python -m pytest -n auto src/
