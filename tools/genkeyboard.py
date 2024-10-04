import argparse
import json
import math
import os
import sys
from pathlib import Path
from typing import Iterator

from jinja2 import Environment, FileSystemLoader, select_autoescape
from kbplacer.kle_serial import Keyboard, parse_kle

ORIGIN_X = 0
ORIGIN_Y = 0
KEY_WIDTH_PX = 64
KEY_HEIGHT_PX = 64


def rotate(origin, point, angle):
    ox, oy = origin
    px, py = point
    radians = math.radians(angle)

    qx = ox + math.cos(radians) * (px - ox) - math.sin(radians) * (py - oy)
    qy = oy + math.sin(radians) * (px - ox) + math.cos(radians) * (py - oy)
    return qx, qy


def calcualte_canvas_size(key_iterator: Iterator) -> tuple[int, int]:
    max_x = 0
    max_y = 0
    for k in key_iterator:
        angle = k.rotation_angle
        if angle != 0:
            # when rotated, check each corner
            x1 = KEY_WIDTH_PX * k.x
            x2 = KEY_WIDTH_PX * k.x + KEY_WIDTH_PX * k.width
            y1 = KEY_HEIGHT_PX * k.y
            y2 = KEY_HEIGHT_PX * k.y + KEY_HEIGHT_PX * k.height

            for x, y in [(x1, y1), (x2, y1), (x1, y2), (x2, y2)]:
                rot_x = KEY_WIDTH_PX * k.rotation_x
                rot_y = KEY_HEIGHT_PX * k.rotation_y
                x, y = rotate((rot_x, rot_y), (x, y), angle)
                x, y = int(x), int(y)
                if x >= max_x:
                    max_x = x
                if y >= max_y:
                    max_y = y

        else:
            # when not rotated, it is safe to check only bottom right corner:
            x = KEY_WIDTH_PX * k.x + KEY_WIDTH_PX * k.width
            y = KEY_HEIGHT_PX * k.y + KEY_HEIGHT_PX * k.height
            if x >= max_x:
                max_x = x
            if y >= max_y:
                max_y = y
    return max_x + 2 * ORIGIN_X, max_y + 2 * ORIGIN_Y


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="KLE edit")
    parser.add_argument("-in", required=True, help="Layout file")

    args = parser.parse_args()
    input_path = getattr(args, "in")

    with open(input_path, "r", encoding="utf-8") as input_file:
        layout = json.load(input_file)

    keyboard = None
    try:
        keyboard = parse_kle(layout)
    except Exception:
        keyboard = Keyboard.from_json(layout)

    if keyboard == None:
        print(f"Unable to get keyboard layout from file '{input_file}'")
        sys.exit(1)

    src_path = Path(os.path.dirname(__file__)) / "../src"
    env = Environment(
        loader=FileSystemLoader(src_path),
        autoescape=select_autoescape(),
    )

    key_data = []
    lookup = [-1] * 256

    for i, k in enumerate(keyboard.keys):
        data = f"{k.x:6}, {k.y:6}, {0:6}, {k.width:6}, {k.height:6}, {k.width2:6}, {k.height2:6}"
        key_data.append(data)
        if labels := k.get_label(0):
            parts = list(map(int, labels.split(",")))
            for p in parts:
                assert p < 255, "unexpected keycode value"
                lookup[p] = i

    lookup = [
        ", ".join(f"{num:4}" for num in lookup[i : i + 8])
        for i in range(0, len(lookup), 8)
    ]

    width, height = calcualte_canvas_size(keyboard.keys)
    print(f"{width=}, {height=}")

    template = env.get_template("keyboard.h.in")
    template.stream(key_data=key_data, lookup=lookup).dump(str(src_path / "keyboard.h"))
