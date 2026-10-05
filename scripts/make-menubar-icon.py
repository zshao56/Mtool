#!/usr/bin/env python3
"""Draw the menu bar icon: the app icon's mark on its own, no tile.

    scripts/make-menubar-icon.py

The ring and its arc are taken from make-icon.py — every proportion is read
from the constants there, so the two can never drift apart. What this adds is
only the framing: crop to the mark, centre it in a square, and write it as an
SVG the asset catalogue keeps as vector and renders as a template image (the
system colours it for light, dark and highlighted menu bars).

Outputs
    Assets.xcassets/MenuBarIcon.imageset/menubar.svg
    Assets.xcassets/MenuBarIcon.imageset/Contents.json
"""
import importlib.util, json, math, os, sys
sys.dont_write_bytecode = True   # importing make-icon.py must not leave a __pycache__ behind

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location("icon", os.path.join(ROOT, "scripts", "make-icon.py"))
icon = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(icon)

OUT = os.path.join(ROOT, "Assets.xcassets", "MenuBarIcon.imageset")

CANVAS = 18      # points. The status item is 22 tall; 18 is what AppKit's own
                 # template glyphs are drawn at, and it leaves room to breathe.
MARK   = 16      # the mark's longer side, in points. A ring reads larger than a
                 # glyph of the same box because it has no empty corners, so it
                 # is set a little under the full canvas.


def geometry():
    """The ring and arc on the 1024 canvas, un-nudged, plus their tight bounds."""
    ra   = (icon.RING_R + icon.RING_W/2) + icon.GAP + icon.ARC_W/2
    half = math.degrees(icon.ARC_LEN / (2*ra))
    a0, a1 = icon.ARC_MID - half, icon.ARC_MID + half
    pt = lambda a, r=ra: (512 + r*math.cos(math.radians(a)), 512 + r*math.sin(math.radians(a)))

    ring_out = icon.RING_R + icon.RING_W/2
    xs = [512 - ring_out, 512 + ring_out]
    ys = [512 - ring_out, 512 + ring_out]
    # The arc's outer edge, sampled, and its two round caps.
    for i in range(201):
        x, y = pt(a0 + (a1 - a0) * i / 200, ra + icon.ARC_W/2)
        xs.append(x); ys.append(y)
    for a in (a0, a1):
        cx, cy = pt(a)
        xs += [cx - icon.ARC_W/2, cx + icon.ARC_W/2]
        ys += [cy - icon.ARC_W/2, cy + icon.ARC_W/2]
    return ra, pt(a0), pt(a1), (min(xs), min(ys), max(xs), max(ys))


def svg():
    ra, (x0, y0), (x1, y1), (l, t, r, b) = geometry()
    side = max(r - l, b - t) * CANVAS / MARK
    # Centre the mark's bounding box. The app icon nudges it instead, but that
    # compensates for a tile edge the eye measures against; here there is no
    # tile, only the gap to the neighbouring icons.
    vx, vy = (l + r)/2 - side/2, (t + b)/2 - side/2
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
            f'viewBox="{vx:.1f} {vy:.1f} {side:.1f} {side:.1f}">'
            f'<circle cx="512" cy="512" r="{icon.RING_R}" fill="none" stroke="#000" '
            f'stroke-width="{icon.RING_W}"/>'
            f'<path d="M{x0:.1f} {y0:.1f} A{ra:.0f} {ra:.0f} 0 0 1 {x1:.1f} {y1:.1f}" fill="none" '
            f'stroke="#000" stroke-width="{icon.ARC_W}" stroke-linecap="round"/></svg>\n')


def main():
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "menubar.svg"), "w") as f:
        f.write(svg())
    contents = {
        "images": [{"filename": "menubar.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True,
                       "template-rendering-intent": "template"},
    }
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")
    print(f"  MenuBarIcon.imageset/menubar.svg  {CANVAS}x{CANVAS}pt")


if __name__ == "__main__":
    main()
