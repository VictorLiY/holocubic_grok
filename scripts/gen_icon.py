#!/usr/bin/env python3
"""生成 128x128 的 app 图标：浅色小球 + 两只眼睛。

眼睛轮廓取 grok-ball 的第 10 组眼环（正面向、双圆眼，最适合当图标），
按世界坐标（头部中心 114.2705，半径 114.2705）等比缩放贴到图标里。
4 倍超采样后再缩小，边缘更干净。
"""
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
PKG = HERE.parent / "package"
DEFAULT_SRC = HERE.parent.parent.parent / "grok-ball" / "src" / "grok-ball.js"
SRC = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else DEFAULT_SRC

EXPR_INDEX = 10
SIZE = 128
SS = 4  # 超采样倍数
BALL_R = 58.0 * SS
BODY_COLOR = (240, 237, 230, 255)
EYE_COLOR = (26, 26, 26, 255)


def load_rings():
    script = f"""
const fs=require('fs'),vm=require('vm');
const src=fs.readFileSync({json.dumps(str(SRC))},'utf8').split(/\\r?\\n/).slice(0,546).join('\\n');
const sb={{window:{{}}}};vm.createContext(sb);vm.runInContext(src,sb);
const R=sb.window.EB_RINGS;
process.stdout.write(JSON.stringify({{head:R.HEAD_C, expr:R.EXPRESSIONS[{EXPR_INDEX}]}}));
"""
    out = subprocess.run(["node", "-e", script], capture_output=True, check=True)
    return json.loads(out.stdout)


def main():
    data = load_rings()
    head_c = data["head"]
    canvas_size = SIZE * SS
    center = canvas_size / 2.0
    scale = BALL_R / head_c

    img = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    draw.ellipse(
        [center - BALL_R, center - BALL_R, center + BALL_R, center + BALL_R],
        fill=BODY_COLOR,
    )

    for ring in data["expr"]:
        pts = [(center + (x - head_c) * scale, center + (y - head_c) * scale) for x, y in ring]
        draw.polygon(pts, fill=EYE_COLOR)

    img = img.resize((SIZE, SIZE), Image.LANCZOS)
    img.save(PKG / "main.png")
    print(f"icon -> {PKG / 'main.png'} ({SIZE}x{SIZE}, expr #{EXPR_INDEX})")


if __name__ == "__main__":
    main()
