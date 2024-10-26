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

run-replay-render:
  rm -rf render-out
  mkdir render-out
  zig build run -- --replay {{event_file}} --render render-out
  cd render-out && ffmpeg -framerate 60 -i "frame%05d.png" -c:v libvpx-vp9 output.webm
  mpv --loop render-out/output.webm

test-kle:
  zig test src/kle.zig

test-queue:
  zig test src/spsc_queue.zig
