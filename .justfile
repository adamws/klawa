event_file := "events.bin"
tracy_path := "/home/aws/git/tracy"

run:
  zig build run

run-tracy:
  zig build run -Dtracy={{tracy_path}} -Dtracy-allocation -Dtracy-callstack

run-record:
  rm events.txt
  zig build run -- --record {{event_file}}

run-replay:
  zig build run -- --replay {{event_file}}

run-replay-loop:
  zig build run -- --replay {{event_file}} --replay-loop

run-replay-render:
  rm -rf render-out
  mkdir render-out
  zig build run -- --replay {{event_file}} --render render-out
  cd render-out && ffmpeg -framerate 60 -i "frame%05d.png" -c:v libvpx-vp9 output.webm
  mpv --loop render-out/output.webm

run-replay-render-tracy:
  rm -rf render-out
  mkdir render-out
  zig build run -Dtracy={{tracy_path}} -Dtracy-allocation -Dtracy-callstack -- --replay {{event_file}} --render render-out

test-kle:
  zig test src/kle.zig

test-queue:
  zig test src/spsc_queue.zig
