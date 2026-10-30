#!/usr/bin/env python3
"""Render the original plugin card artwork; development requires FFmpeg."""
from pathlib import Path
import math
import subprocess
import tempfile

WIDTH, HEIGHT = 960, 540


def pixel(x, y):
    glow = math.exp(-((x - 780) ** 2 + (y - 200) ** 2) / 80000)
    color = [int(15 + 16 * glow), int(18 + 12 * glow), int(28 + 28 * glow)]
    # Three illustrated compositor windows, each with an animated-shader palette.
    for index, (left, top) in enumerate(((552, 68), (602, 174), (510, 284))):
        width, height, radius = 326, 180, 15
        dx = max(abs(x - left - width / 2) - width / 2 + radius, 0)
        dy = max(abs(y - top - height / 2) - height / 2 + radius, 0)
        distance = math.hypot(dx, dy) - radius
        inside = left <= x <= left + width and top <= y <= top + height and distance <= 0
        if not inside:
            continue
        edge = min(x - left, left + width - x, y - top, top + height - y, -distance)
        phase = (x + y) / 95 + index * 1.7
        hue = [int(140 + 90 * math.sin(phase)), int(150 + 80 * math.sin(phase + 2)), int(190 + 60 * math.sin(phase + 4))]
        if edge < 4:
            color = hue
        else:
            strength = 0.16 * math.exp(-edge / 32)
            color = [int(base + tint * strength) for base, tint in zip((24, 29, 42), hue)]
            if top + 14 <= y < top + 19 and left + 18 <= x < left + 90:
                color = [82, 90, 111]
            if top + 43 <= y < top + 45:
                color = [44, 49, 66]
            if top + 66 <= y < top + 131 and left + 23 <= x < left + 303:
                wave = math.sin((x - left) / 28 + (y - top) / 15 + index)
                color = [int(30 + 12 * (wave + 1)), int(40 + 14 * (wave + 1)), int(62 + 20 * (wave + 1))]
    return bytes(color)


def main():
    destination = Path(__file__).resolve().parents[1] / 'umbriel-shaders/thumbnail.webp'
    with tempfile.TemporaryDirectory(prefix='umbriel-thumbnail-') as temp:
        image = Path(temp) / 'art.ppm'
        image.write_bytes(f'P6\n{WIDTH} {HEIGHT}\n255\n'.encode() + b''.join(
            pixel(x, y) for y in range(HEIGHT) for x in range(WIDTH)
        ))
        labels = [
            ('NOCTALIA PLUGIN', 23, 55, 113, '0x9ca8bf'),
            ('Umbriel', 59, 51, 175, '0xf2f4fa'),
            ('Shaders', 59, 51, 245, '0xc3adff'),
            ('Browse. Apply. Restore.', 23, 55, 343, '0xb8c1d4'),
        ]
        filters = ','.join(
            f"drawtext=font='DejaVu Sans':text='{text}':fontsize={size}:x={x}:y={y}:fontcolor={color}"
            for text, size, x, y, color in labels
        )
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(image),
                        '-vf', filters, '-frames:v', '1', '-c:v', 'libwebp', '-quality', '90',
                        str(destination)], check=True)
    print(destination)


if __name__ == '__main__':
    main()
