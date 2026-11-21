#!/usr/bin/env python3
"""Рисует значок приложения — пиксельную букву A на чёрном фоне — и раскладывает его по всем системам.
Запуск из apps/client: python3 tool/make_icons.py. Сторонние библиотеки не нужны."""
import os
import struct
import zlib

GLYPH = [
    "..###..",
    ".##.##.",
    "##...##",
    "##...##",
    "#######",
    "##...##",
    "##...##",
]
COLS, ROWS = len(GLYPH[0]), len(GLYPH)
BLACK, WHITE, CLEAR = (0, 0, 0, 255), (255, 255, 255, 255), (0, 0, 0, 0)


def render(size, glyph_height, background=BLACK, plate=None, radius=0.0):
    """glyph_height — высота буквы в долях стороны. plate — доля стороны под чёрную плашку со скруглением
    (значок macOS), вне плашки прозрачно."""
    cell = glyph_height / ROWS
    left, top = (1 - cell * COLS) / 2, (1 - glyph_height) / 2
    rows = []
    for py in range(size):
        row = bytearray()
        for px in range(size):
            x, y = (px + 0.5) / size, (py + 0.5) / size
            color = background
            if plate is not None:
                color = BLACK if inside_plate(x, y, plate, radius) else CLEAR
            gx, gy = (x - left) / cell, (y - top) / cell
            if 0 <= gx < COLS and 0 <= gy < ROWS and GLYPH[int(gy)][int(gx)] == "#":
                color = WHITE
            row += bytes(color)
        rows.append(bytes(row))
    return rows


def inside_plate(x, y, plate, radius):
    lo, hi = (1 - plate) / 2, (1 + plate) / 2
    if not (lo <= x <= hi and lo <= y <= hi):
        return False
    cx = min(max(x, lo + radius), hi - radius)
    cy = min(max(y, lo + radius), hi - radius)
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2


def png(rows, alpha=True):
    size = len(rows)
    raw = bytearray()
    for row in rows:
        raw.append(0)
        raw += row if alpha else b"".join(row[i:i + 3] for i in range(0, len(row), 4))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    header = struct.pack(">IIBBBBB", size, size, 8, 6 if alpha else 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def ico(sizes):
    images = [png(render(s, 0.54)) for s in sizes]
    out = struct.pack("<HHH", 0, 1, len(sizes))
    offset = 6 + 16 * len(sizes)
    for s, data in zip(sizes, images):
        out += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    return out + b"".join(images)


def main():
    full = lambda s: png(render(s, 0.54), alpha=False)  # noqa: E731
    write("assets/icon/icon-1024.png", full(1024))
    # Android: обычный значок и слой для адаптивного (система обрезает края, буква меньше)
    for name, scale in {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}.items():
        base = f"android/app/src/main/res/mipmap-{name}"
        write(f"{base}/ic_launcher.png", full(int(48 * scale)))
        write(f"{base}/ic_launcher_foreground.png", png(render(int(108 * scale), 0.34, background=CLEAR)))
    write("assets/icon/foreground-432.png", png(render(432, 0.34, background=CLEAR)))
    # iOS: без прозрачности, углы скругляет система
    ios = "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for name in os.listdir(ios):
        if name.endswith(".png"):
            points, scale = name[len("Icon-App-"):-len(".png")].split("@")
            write(f"{ios}/{name}", full(round(float(points.split("x")[0]) * int(scale[0]))))
    # macOS: чёрная плашка со скруглёнными углами и полями, как у остальных программ
    for s in (16, 32, 64, 128, 256, 512, 1024):
        write(f"macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{s}.png", png(render(s, 0.44, plate=0.805, radius=0.18)))
    write("windows/runner/resources/app_icon.ico", ico([16, 24, 32, 48, 64, 256]))
    print("Значки обновлены")


if __name__ == "__main__":
    main()
