#!/bin/bash

set -e
set -u

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# TODO: should check if free:
FAKE_DISPLAY=:99
APP=${SCRIPT_DIR}/../zig-out/bin/klawa
TEST_EVENTS=test_events.bin
TEST_RENDER_DIR=render-out

# TODO: add option to choose display, for local development Xephyr is better
# but on CI Xvfb is required

#Xephyr -br -ac -noreset -screen 960x320 $FAKE_DISPLAY &
#DISPLAY_PID=$!

Xvfb -ac $FAKE_DISPLAY -screen 0 960x320x24 > /dev/null 2>&1 &
DISPLAY_PID=$!

# wait for display
sleep 10

DISPLAY=$FAKE_DISPLAY $APP --record $TEST_EVENTS &
APP_PID=$!

# wait for tested app
sleep 10

# simulate some input
DISPLAY=$FAKE_DISPLAY xdotool type --delay 500 "this is test case number 1"
kill -9 $APP_PID

mkdir $TEST_RENDER_DIR
DISPLAY=$FAKE_DISPLAY $APP --replay $TEST_EVENTS --render $TEST_RENDER_DIR
kill -9 $DISPLAY_PID

rm $TEST_EVENTS

cd $TEST_RENDER_DIR && ffmpeg -y -framerate 60 -s 960x320 -pix_fmt rgba -i "frame%05d.raw" -c:v libvpx-vp9 ../output.webm
cd -

rm -rf $TEST_RENDER_DIR
