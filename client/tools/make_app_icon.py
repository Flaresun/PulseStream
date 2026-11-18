#!/usr/bin/env python3
"""Generates the PulseStream app icon assets.

Draws the mark directly rather than shipping a binary-only asset, so the logo
can be tweaked (colours, stroke weight, pulse shape) and regenerated:

    python3 client/tools/make_app_icon.py

Writes the three appearances iOS asks for (light, dark, tinted) into
PulseStream/Assets.xcassets/AppIcon.appiconset/. Corners are left square —
iOS applies its own mask.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 4  # supersampling factor; the mark is drawn big and downsampled for AA
OUT_DIR = Path(__file__).resolve().parent.parent / "PulseStream/Assets.xcassets/AppIcon.appiconset"

# Matches Color.neonBlue in Models.swift, which marks S3-cached tracks.
NEON = (64, 199, 255)


def gradient(top_left, bottom_right, size):
    """Diagonal two-stop linear gradient, drawn small and scaled up."""
    small = Image.new("RGB", (64, 64))
    px = small.load()
    for y in range(64):
        for x in range(64):
            t = (x + y) / 126.0
            px[x, y] = tuple(
                round(a + (b - a) * t) for a, b in zip(top_left, bottom_right)
            )
    return small.resize((size, size), Image.BICUBIC)


def pulse_points(size):
    """A single heartbeat spike on a flat baseline, as fractions of the canvas."""
    mid = 0.5
    pts = [
        (0.13, mid),
        (0.30, mid),
        (0.38, mid + 0.13),   # small dip into the beat
        (0.47, mid - 0.27),   # the spike
        (0.56, mid + 0.19),   # overshoot below
        (0.64, mid),
        (0.87, mid),
    ]
    return [(round(x * size), round(y * size)) for x, y in pts]


def draw_mark(background, stroke, glow, glow_radius=0.0):
    """Composites the pulse stroke over `background` at full supersampled size."""
    canvas = background.resize((SIZE * SS, SIZE * SS), Image.BICUBIC).convert("RGB")
    points = pulse_points(SIZE * SS)
    width = round(0.062 * SIZE * SS)

    if glow_radius:
        layer = Image.new("RGB", canvas.size, (0, 0, 0))
        ImageDraw.Draw(layer).line(points, fill=glow, width=width * 2, joint="curve")
        layer = layer.filter(ImageFilter.GaussianBlur(glow_radius * SS))
        canvas = Image.blend(canvas, Image.new("RGB", canvas.size, glow), 0.0)
        canvas = Image.composite(
            Image.blend(canvas, layer, 0.55), canvas, layer.convert("L")
        )

    draw = ImageDraw.Draw(canvas)
    draw.line(points, fill=stroke, width=width, joint="curve")
    # joint="curve" rounds the interior joins; cap the two ends to match.
    r = width // 2
    for end in (points[0], points[-1]):
        draw.ellipse([end[0] - r, end[1] - r, end[0] + r, end[1] + r], fill=stroke)

    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # Light: neon-to-deep-blue field, white mark.
    draw_mark(
        gradient((34, 168, 255), (10, 22, 72), 64),
        stroke=(255, 255, 255),
        glow=(120, 215, 255),
        glow_radius=0,  # white on blue reads crisply without a halo
    ).save(OUT_DIR / "AppIcon.png")

    # Dark: near-black field, the mark itself carries the colour.
    draw_mark(
        gradient((22, 28, 46), (6, 8, 16), 64),
        stroke=NEON,
        glow=NEON,
        glow_radius=22,
    ).save(OUT_DIR / "AppIcon-Dark.png")

    # Tinted: iOS recolours a greyscale image, so ship luminance only.
    draw_mark(
        gradient((42, 42, 42), (12, 12, 12), 64),
        stroke=(236, 236, 236),
        glow=(150, 150, 150),
        glow_radius=0,
    ).save(OUT_DIR / "AppIcon-Tinted.png")

    print(f"wrote 3 icons to {OUT_DIR}")


if __name__ == "__main__":
    main()
