event_file := "events.bin"
atlas_file := "klawa_atlas.png"
tracy_path := "/home/aws/git/tracy"

run:
  zig build run

build-win:
  zig build -Dtarget=x86_64-windows

run-win:
  wine zig-out/bin/klawa.exe

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
  zig build run -- --replay {{event_file}} --render output.webm
  mpv --loop output.webm

run-replay-render-tracy:
  rm -rf frames.raw
  zig build run -Dtracy={{tracy_path}} -Dtracy-allocation -Dtracy-callstack -- --replay {{event_file}} --render output.webm

run-save-as-atlas:
  rm -f {{atlas_file}}
  zig build run -- --save-atlas {{atlas_file}}

test-kle:
  zig test src/kle.zig

test-queue:
  zig test src/spsc_queue.zig

test-config:
  zig test src/config.zig

test:
  zig build test

pytest:
  # TODO: enable -n auto when rendering with low framerate fixed
  cd tests && . .env/bin/activate && python -m pytest src/

run-atlas-generator:
  zig build run -- --keycap ./src/resources/keycaps_default.png --output ./src/resources/keycaps_default_atlas.png
  zig build run -- --keycap ./src/resources/keycaps_kle.png --output ./src/resources/keycaps_kle_atlas.png
  zig build run -- --keycap ./src/resources/keycaps_kle_with_gaps.png --output ./src/resources/keycaps_kle_with_gaps_atlas.png
  zig build run -- --keycap ./src/resources/keycaps_vortex_pok3r.png --output ./src/resources/keycaps_vortex_pok3r_atlas.png
