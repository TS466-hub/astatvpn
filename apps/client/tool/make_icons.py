#!/usr/bin/env python3
"""Рисует монохромную букву A и генерирует значки для всех платформ.

Запуск из apps/client: python3 tool/make_icons.py. Сторонние библиотеки не нужны.
"""
import math
import os
import struct
import zlib

BLACK, WHITE, CLEAR = 0, 246, (0, 0)


def coverage(distance, size):
    """Сглаживает границу фигуры на ширину одного пикселя."""
    return min(1, max(0, 0.5 - distance * size))


def segment_distance(x, y, start, end):
    dx, dy = end[0] - start[0], end[1] - start[1]
    t = min(1, max(0, ((x - start[0]) * dx + (y - start[1]) * dy) / (dx * dx + dy * dy)))
    return math.hypot(x - start[0] - t * dx, y - start[1] - t * dy)


def render(size, glyph_height, background=(BLACK, 255), plate=None, radius=0.0):
    """Плашка с прозрачными полями используется в macOS и Windows."""
    stroke = glyph_height * 0.151
    left, right = 0.5 - glyph_height * 0.385, 0.5 + glyph_height * 0.385
    top = 0.49 - glyph_height / 2 + stroke / 2
    bottom = 0.49 + glyph_height / 2 - stroke / 2
    beam = top + (bottom - top) * 0.68
    apex = (0.5, top)
    segments = [
        ((left, bottom), apex),
        (apex, (right, bottom)),
        ((0.5 + (left - 0.5) * 0.68, beam), (0.5 + (right - 0.5) * 0.68, beam)),
    ]

    rows = []
    for py in range(size):
        row = bytearray()
        for px in range(size):
            x, y = (px + 0.5) / size, (py + 0.5) / size
            shade, alpha = background
            if plate is not None:
                qx = abs(x - 0.5) - plate / 2 + radius
                qy = abs(y - 0.5) - plate / 2 + radius
                distance = math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
                alpha = round(255 * coverage(distance, size))
            if left - stroke <= x <= right + stroke and top - stroke <= y <= bottom + stroke:
                distance = min(segment_distance(x, y, start, end) for start, end in segments)
                ink = coverage(distance - stroke / 2, size)
                if ink > 0:
                    opacity = ink + alpha / 255 * (1 - ink)
                    shade = round((WHITE * ink + shade * alpha / 255 * (1 - ink)) / opacity)
                    alpha = round(255 * opacity)
            row.extend((shade, shade, shade, alpha))
        rows.append(bytes(row))
    return rows


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
    images = [png(render(s, 0.60, plate=0.94, radius=0.175)) for s in sizes]
    out = struct.pack("<HHH", 0, 1, len(sizes))
    offset = 6 + 16 * len(sizes)
    for s, data in zip(sizes, images):
        out += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    return out + b"".join(images)


def main():
    def full(size):
        return png(render(size, 0.55), alpha=False)

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
        write(f"macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{s}.png", png(render(s, 0.46, plate=0.805, radius=0.18)))
    write("windows/runner/resources/app_icon.ico", ico([16, 24, 32, 48, 64, 256]))
    print("Значки обновлены")


if __name__ == "__main__":
    main()
