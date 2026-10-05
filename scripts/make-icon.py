#!/usr/bin/env python3
"""Draw the app icon and write every file the project needs.

The icon is a ring with a short arc outside its lower right — the letter Q,
and at the same time the app's own shape: the wheel of actions, with the
submenu that swings out beside it.

Outputs
    Assets.xcassets/AppIcon.appiconset/icon_*.png   what the app ships
    Assets.xcassets/AppLogo.imageset/logo.png       the sidebar and About page
                                                    draw their own copy
    design/icon/icon-1024-square.png                full bleed, no corners,
                                                    no shadow — hand this to
                                                    anything that applies its
                                                    own mask
    design/icon/icon-1024-rounded.png               the macOS shape, for eyes

Every number here was chosen by looking, so each is written down rather than
derived. Re-run after changing any of them; nothing else draws the icon.
"""
import math, os, subprocess, sys

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ROOT   = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "Assets.xcassets", "AppIcon.appiconset")
LOGO    = os.path.join(ROOT, "Assets.xcassets", "AppLogo.imageset", "logo.png")
MASTERS = os.path.join(ROOT, "design", "icon")

# ── the mark, on a 1024 canvas ────────────────────────────────────────────
RING_R, RING_W = 234, 80        # ring centreline radius, stroke
GAP            = 44             # bare canvas between ring and arc
ARC_W          = 72             # arc stroke: 10% finer than the ring, because a
                                # short stubby shape reads heavier than a long line
ARC_LEN        = 130.4          # arc length, caps excluded — with the caps the
                                # arc is 202 long, which is the proportion picked
ARC_MID        = 48             # degrees clockwise from 3 o'clock
NUDGE          = -10            # the whole mark up and left. The arc hangs at the
                                # lower right, so centring the ring lets the pair
                                # sag: measured on a raster, the combined centre of
                                # mass sits 23 right and 26 below the canvas centre.
                                # This pulls back 10 of that, not all 23 — correcting
                                # it fully makes the RING look off-centre, and the
                                # ring is what the eye takes for the subject.

# ── the tile ──────────────────────────────────────────────────────────────
TOP, BOTTOM = "#2563EB", "#06B6D4"   # deep blue above, bright cyan below
HIGHLIGHT   = 0.28                   # white, radial, from the top edge
RIM         = 0.18                   # white hairline along the inside of the edge
# The gradient runs dark-to-light top-to-bottom, the opposite of the usual, and
# that is the point: a lit bottom edge reads as light coming THROUGH the tile
# rather than falling ON it — the same glass the popup itself is made of.
# It only works because the top is dark. White laid over a dark colour brightens
# it; white laid over an already-bright one bleaches it (bright cyan loses 24
# points of saturation under this same highlight). So TOP, BOTTOM and HIGHLIGHT
# are one decision, not three: flipping the order without also dropping the
# highlight is what turns the icon grey.

# ── the tile's outline ────────────────────────────────────────────────────
# Not a rounded rectangle and not a superellipse: macOS uses a continuous-
# curvature corner that neither reproduces. This path came out of the system's
# own RoundedRectangle(cornerRadius: 185.4, style: .continuous) over the
# 824-point body that Apple's template places in a 1024 canvas.
# Measured against a real system icon's alpha, this tracks it to 1.3px on a
# 1024 canvas, where the best superellipse of any exponent managed only 4.0.
BODY, MARGIN, CORNER = 824, 100, 185.4
SHAPE = (
    "M924.000 512.000L924.000 640.586C924.000 722.194 924.000 762.997 910.111 806.921"
    "C892.656 854.878 854.878 892.656 806.921 910.111C762.997 924.000 722.194 924.000 640.586 924.000"
    "L383.414 924.000C301.806 924.000 261.003 924.000 217.079 910.111"
    "C169.122 892.656 131.344 854.878 113.889 806.921C100.000 762.997 100.000 722.194 100.000 640.586"
    "L100.000 383.414C100.000 301.806 100.000 261.003 113.889 217.079"
    "C131.344 169.122 169.122 131.344 217.079 113.889C261.003 100.000 301.806 100.000 383.414 100.000"
    "L640.586 100.000C722.194 100.000 762.997 100.000 806.921 113.889"
    "C854.878 131.344 892.656 169.122 910.111 217.079C924.000 261.003 924.000 301.806 924.000 383.414Z"
)
SQUARE = "M0 0L1024 0L1024 1024L0 1024Z"

SIZES = [16, 32, 64, 128, 256, 512, 1024]


def mark():
    """The ring and its arc, white, as SVG."""
    ra   = (RING_R + RING_W/2) + GAP + ARC_W/2
    half = math.degrees(ARC_LEN / (2*ra))
    pt = lambda a: (512 + ra*math.cos(math.radians(a)), 512 + ra*math.sin(math.radians(a)))
    x0, y0 = pt(ARC_MID - half)
    x1, y1 = pt(ARC_MID + half)
    return (f'<g transform="translate({NUDGE},{NUDGE})">'
            f'<circle cx="512" cy="512" r="{RING_R}" fill="none" stroke="#fff" stroke-width="{RING_W}"/>'
            f'<path d="M{x0:.1f} {y0:.1f} A{ra:.0f} {ra:.0f} 0 0 1 {x1:.1f} {y1:.1f}" '
            f'fill="none" stroke="#fff" stroke-width="{ARC_W}" stroke-linecap="round"/></g>')


def document(size, shape="rounded"):
    """One icon. `shape` is "rounded" for the macOS tile, "square" for the master."""
    rounded = shape == "rounded"
    outline = SHAPE if rounded else SQUARE
    # The shadow and the rim belong to the tile, not to the artwork: a master
    # that something else will mask must carry neither.
    shadow = (f'<g filter="url(#f)"><path d="{outline}" fill="url(#g)"/></g>'
              if rounded else f'<path d="{outline}" fill="url(#g)"/>')
    # The rim is drawn INSIDE the clip. Stroking the outline directly puts half
    # the line outside the silhouette, where it shows up as a pale fringe over
    # the shadow — a real defect, not a highlight. Clipped, a 3-wide stroke
    # leaves the 1.5 inside that the design was approved with; set RIM to 0 to
    # drop the rim altogether.
    rim = (f'<path d="{outline}" fill="none" stroke="#fff" stroke-opacity="{RIM}" stroke-width="3"/>'
           if rounded else "")
    return f"""<!doctype html><html><head><meta charset=utf-8>
<style>html,body{{margin:0;padding:0;background:transparent}}</style></head><body>
<svg width="{size}" height="{size}" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg"><defs>
 <linearGradient id="g" x1="0" y1="0" x2="0.35" y2="1" gradientUnits="objectBoundingBox">
   <stop offset="0" stop-color="{TOP}"/><stop offset="1" stop-color="{BOTTOM}"/></linearGradient>
 <radialGradient id="s" cx="0.5" cy="0.02" r="0.85">
   <stop offset="0" stop-color="#fff" stop-opacity="{HIGHLIGHT}"/>
   <stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
 <clipPath id="c"><path d="{outline}"/></clipPath>
 <filter id="f" x="-20%" y="-20%" width="140%" height="145%">
   <feDropShadow dx="0" dy="16" stdDeviation="22" flood-color="#000" flood-opacity=".30"/></filter>
</defs>
{shadow}
<g clip-path="url(#c)">
  <path d="{outline}" fill="url(#s)"/>
  {mark()}
  {rim}
</g></svg></body></html>"""


def render(html, dest, px):
    tmp = os.path.join(ROOT, ".icon-tmp.html")
    open(tmp, "w").write(html)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    subprocess.run([CHROME, "--headless", "--disable-gpu",
                    "--default-background-color=00000000",
                    f"--screenshot={dest}", f"--window-size={px},{px}",
                    "--hide-scrollbars", "--virtual-time-budget=1500",
                    "file://" + tmp], capture_output=True)
    os.remove(tmp)
    return os.path.getsize(dest)


def main():
    if not os.path.exists(CHROME):
        sys.exit(f"need Chrome to rasterise: {CHROME}")
    for px in SIZES:
        d = os.path.join(ICONSET, f"icon_{px}x{px}.png")
        print(f"  icon_{px}x{px}.png{'':>{max(0,8-len(str(px))*2)}}  {render(document(px), d, px):>8,} bytes")
    print(f"  AppLogo/logo.png            {render(document(1024), LOGO, 1024):>8,} bytes")
    for name, shape in (("icon-1024-square", "square"), ("icon-1024-rounded", "rounded")):
        d = os.path.join(MASTERS, name + ".png")
        print(f"  design/icon/{name}.png  {render(document(1024, shape), d, 1024):>8,} bytes")


if __name__ == "__main__":
    main()
