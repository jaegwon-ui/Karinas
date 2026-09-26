#!/usr/bin/env python3
"""3D 렌더 프레임을 Aseprite 덧그리기용 파일로 만든다.

레이어 (아래 → 위)
  - "3D 가이드": 렌더한 프레임. 잠겨 있고 반투명하다.
  - "스케치", "도트": 비어 있다. 여기에 그린다.
태그마다 프레임을 골라 넣고, 색조 이동 팔레트를 함께 넣는다.

예:
  python3 tools/aseprite_starter.py --out art/knight_paintover.aseprite \\
      --tag 전투대기:프레임폴더:10:200 --tag 공격:프레임폴더:5:100 \\
      --palette-out art/palettes/karinas_knight.gpl

--tag 형식은 "이름:폴더:간격:프레임길이(ms)". 폴더의 frame_*.png 중 간격마다 한 장씩 고른다.
파일 형식: https://github.com/aseprite/aseprite/blob/main/docs/ase-file-specs.md
"""

import argparse
import colorsys
import glob
import os
import struct
import zlib

from PIL import Image

LAYER_VISIBLE = 1
LAYER_EDITABLE = 2
HEADER_LAYER_OPACITY_VALID = 1

TAG_COLORS = [(255, 120, 150), (120, 190, 255), (150, 230, 140), (255, 210, 110)]


# ---------------------------------------------------------------- 팔레트

def ramp(name, hue, sat, count, dark=0.16, light=0.96, shadow_shift=28.0, highlight_shift=22.0):
    """어두울수록 푸른 보라 쪽으로, 밝을수록 노랑 쪽으로 색조를 옮긴 명암 단계."""

    def toward(target):
        diff = (target - hue + 540.0) % 360.0 - 180.0
        return 1.0 if diff > 0 else -1.0

    colors = []
    for i in range(count):
        t = i / (count - 1)
        if t < 0.5:
            h = hue + toward(250.0) * shadow_shift * (0.5 - t) * 2.0
        else:
            h = hue + toward(60.0) * highlight_shift * (t - 0.5) * 2.0
        s = sat * (1.0 - 0.45 * abs(2.0 * t - 1.0) ** 1.5)
        v = dark + (light - dark) * t
        r, g, b = colorsys.hsv_to_rgb((h % 360.0) / 360.0, max(0.0, min(1.0, s)), v)
        colors.append(("%s %d" % (name, i + 1), (round(r * 255), round(g * 255), round(b * 255))))
    return colors


def knight_palette():
    ramps = [
        ramp("외곽", 270, 0.45, 3, dark=0.07, light=0.28),
        ramp("망토", 352, 0.78, 6),
        ramp("강철", 218, 0.24, 6),
        ramp("금장", 40, 0.72, 5, dark=0.3, highlight_shift=10.0),
        ramp("피부", 16, 0.38, 5, dark=0.35, light=0.99),
        ramp("흑청 머리", 226, 0.5, 5, dark=0.1, light=0.8),
        ramp("적갈 머리", 10, 0.72, 5, dark=0.18, light=0.95),
        ramp("가죽", 22, 0.5, 4, dark=0.14, light=0.62),
    ]
    return ramps


def write_gpl(path, ramps, title):
    lines = ["GIMP Palette", "Name: %s" % title, "Columns: 6", "#"]
    for colors in ramps:
        lines.append("# %s" % colors[0][0].rsplit(" ", 1)[0])
        for name, (r, g, b) in colors:
            lines.append("%3d %3d %3d\t%s" % (r, g, b, name))
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


# ---------------------------------------------------------------- .aseprite 쓰기

def ase_string(text):
    raw = text.encode("utf-8")
    return struct.pack("<H", len(raw)) + raw


def chunk(chunk_type, data):
    return struct.pack("<IH", len(data) + 6, chunk_type) + data


def color_profile_chunk():
    return chunk(0x2007, struct.pack("<HHI8x", 1, 0, 0))  # sRGB


def palette_chunk(colors):
    data = struct.pack("<III8x", len(colors), 0, len(colors) - 1)
    for name, (r, g, b) in colors:
        data += struct.pack("<HBBBB", 1, r, g, b, 255) + ase_string(name)
    return chunk(0x2019, data)


def layer_chunk(name, flags, opacity=255):
    data = struct.pack("<HHHHHHB3x", flags, 0, 0, 0, 0, 0, opacity) + ase_string(name)
    return chunk(0x2004, data)


def tags_chunk(tags):
    data = struct.pack("<H8x", len(tags))
    for i, (name, first, last) in enumerate(tags):
        r, g, b = TAG_COLORS[i % len(TAG_COLORS)]
        data += struct.pack("<HHBH6xBBBx", first, last, 0, 0, r, g, b) + ase_string(name)
    return chunk(0x2018, data)


def cel_chunk(layer_index, image):
    """투명한 테두리를 잘라낸 RGBA 이미지를 압축 셀로 넣는다. 비어 있으면 None."""
    box = image.getbbox()
    if box is None:
        return None
    part = image.crop(box)
    data = struct.pack("<HhhBHh5x", layer_index, box[0], box[1], 255, 2, 0)
    data += struct.pack("<HH", part.width, part.height)
    data += zlib.compress(part.tobytes(), 9)
    return chunk(0x2005, data)


def frame_bytes(chunks, duration_ms):
    body = b"".join(chunks)
    count = len(chunks)
    header = struct.pack("<IHHH2xI", 16 + len(body), 0xF1FA, min(count, 0xFFFF), duration_ms, count)
    return header + body


def write_aseprite(path, width, height, frames, tags, palette, guide_opacity):
    """frames: [(RGBA 이미지, 길이 ms)], tags: [(이름, 첫 프레임, 끝 프레임)]"""
    layers = [
        ("3D 가이드", LAYER_VISIBLE, guide_opacity),
        ("스케치", LAYER_VISIBLE | LAYER_EDITABLE, 255),
        ("도트", LAYER_VISIBLE | LAYER_EDITABLE, 255),
    ]
    body = b""
    for index, (image, duration) in enumerate(frames):
        chunks = []
        if index == 0:
            chunks.append(color_profile_chunk())
            chunks.append(palette_chunk(palette))
            for name, flags, opacity in layers:
                chunks.append(layer_chunk(name, flags, opacity))
            chunks.append(tags_chunk(tags))
        cel = cel_chunk(0, image)
        if cel:
            chunks.append(cel)
        body += frame_bytes(chunks, duration)

    header = struct.pack(
        "<IHHHHHIHIIB3xHBBhhHH84x",
        128 + len(body), 0xA5E0, len(frames), width, height, 32,
        HEADER_LAYER_OPACITY_VALID, 100, 0, 0, 0,
        len(palette) if len(palette) <= 256 else 0, 1, 1, 0, 0, 16, 16,
    )
    assert len(header) == 128
    with open(path, "wb") as f:
        f.write(header + body)


# ---------------------------------------------------------------- 실행

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True)
    parser.add_argument("--tag", action="append", required=True, help="이름:폴더:간격:프레임길이ms")
    parser.add_argument("--guide-opacity", type=int, default=110)
    parser.add_argument("--palette-out")
    args = parser.parse_args()

    frames = []
    tags = []
    for spec in args.tag:
        name, folder, step, duration = spec.rsplit(":", 3)
        files = sorted(glob.glob(os.path.join(folder, "frame_*.png")))[:: int(step)]
        if not files:
            raise SystemExit("프레임이 없어: %s" % folder)
        first = len(frames)
        for file in files:
            frames.append((Image.open(file).convert("RGBA"), int(duration)))
        tags.append((name, first, len(frames) - 1))

    width, height = frames[0][0].size
    ramps = knight_palette()
    palette = [color for colors in ramps for color in colors]
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    write_aseprite(args.out, width, height, frames, tags, palette, args.guide_opacity)
    print("wrote %s: %dx%d, %d frames, tags %s, %d colors" % (args.out, width, height, len(frames), tags, len(palette)))

    if args.palette_out:
        os.makedirs(os.path.dirname(os.path.abspath(args.palette_out)), exist_ok=True)
        write_gpl(args.palette_out, ramps, "Karinas Knight")
        print("wrote %s" % args.palette_out)


if __name__ == "__main__":
    main()
