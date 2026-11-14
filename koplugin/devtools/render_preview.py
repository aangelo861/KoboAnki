#!/usr/bin/env python3
"""Draw the JSON written by preview_statsview.lua into PNGs (Pillow), with the Noto Sans fonts
KOReader uses for its UI.

    python3 render_preview.py OUT/statsview-*.json --fonts DIR [--scale 0.5]

DIR must contain NotoSans-Regular.ttf and NotoSans-Bold.ttf (KOReader ships them in fonts/noto/).
"""

import argparse
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--fonts", required=True)
    ap.add_argument("--scale", type=float, default=1.0, help="also write a scaled copy (e.g. 0.5)")
    args = ap.parse_args()
    cache = {}

    def font(px, bold):
        key = (px, bold)
        if key not in cache:
            name = "NotoSans-Bold.ttf" if bold else "NotoSans-Regular.ttf"
            cache[key] = ImageFont.truetype(os.path.join(args.fonts, name), px)
        return cache[key]

    for path in args.files:
        with open(path) as f:
            page = json.load(f)
        img = Image.new("RGB", (page["w"], page["h"]), "#FFFFFF")
        draw = ImageDraw.Draw(img)
        for op in page["ops"]:
            kind = op["op"]
            if kind == "rect":
                box = [op["x"], op["y"], op["x"] + op["w"] - 1, op["y"] + op["h"] - 1]
                r = min(op.get("r") or 0, op["w"] // 2, op["h"] // 2)
                if r > 0:
                    draw.rounded_rectangle(box, radius=r, fill=op["color"])
                else:
                    draw.rectangle(box, fill=op["color"])
            elif kind == "border":
                box = [op["x"], op["y"], op["x"] + op["w"] - 1, op["y"] + op["h"] - 1]
                draw.rectangle(box, outline=op["color"], width=op["bw"])
            elif kind == "circle":
                r = op["r"]
                box = [op["x"] - r, op["y"] - r, op["x"] + r, op["y"] + r]
                if op.get("lw") and op["lw"] < r:
                    draw.ellipse(box, outline=op["color"], width=op["lw"])
                else:
                    draw.ellipse(box, fill=op["color"])
            elif kind == "text":
                draw.text((op["x"], op["y"] + op["base"]), op["text"], font=font(op["px"], op["bold"]),
                          fill=op["color"], anchor="ls")
            elif kind == "image":
                # pixels dumped by the recorder (already at the blitted size); grey placeholder otherwise
                if op.get("file") and os.path.exists(op["file"]):
                    with Image.open(op["file"]) as pic:
                        img.paste(pic.convert("RGB"), (op["x"], op["y"]))
                else:
                    draw.rectangle([op["x"], op["y"], op["x"] + op["w"] - 1, op["y"] + op["h"] - 1],
                                   fill="#BBBBBB")
        out = os.path.splitext(path)[0] + ".png"
        img.save(out)
        print(out)
        if args.scale and args.scale != 1.0:
            small = img.resize((int(page["w"] * args.scale), int(page["h"] * args.scale)), Image.LANCZOS)
            small_out = os.path.splitext(path)[0] + "-small.png"
            small.save(small_out)
            print(small_out)


if __name__ == "__main__":
    sys.exit(main())
