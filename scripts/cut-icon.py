#!/usr/bin/env python3
"""Cut a full-bleed square master into the macOS icon shape, at every size.

Takes artwork that runs edge to edge — a painted master, or the square export
from make-icon.py — and produces what the app ships: the art clipped to the
macOS tile, with the tile's shadow underneath.

    scripts/cut-icon.py design/icon/some-master.png

The master is NOT scaled down to fit the tile. The tile is an 824-point body
inside a 1024 canvas, so clipping crops 100 points off each side of the master
and the artwork keeps its size. That is what full bleed means: the corners are
meant to be thrown away.

Writes the seven catalogue sizes, the copy the sidebar and About page draw
themselves, and design/icon/icon-1024-rounded.png for looking at.
"""
import base64, os, subprocess, sys

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ROOT   = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "Assets.xcassets", "AppIcon.appiconset")
LOGO    = os.path.join(ROOT, "Assets.xcassets", "AppLogo.imageset", "logo.png")
PREVIEW = os.path.join(ROOT, "design", "icon", "icon-1024-rounded.png")

# The macOS tile, from the system's own continuous-curvature corner:
# RoundedRectangle(cornerRadius: 185.4, style: .continuous) over the 824-point
# body Apple's template centres in a 1024 canvas. Measured against a real system
# icon's alpha this tracks it to 1.3px; a superellipse could not get under 4.0.
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
SIZES = [16, 32, 64, 128, 256, 512, 1024]


def document(uri, size):
    # The shadow is cast by the tile, not by the artwork, so it is drawn as a
    # filled copy of the outline underneath and then covered by the clipped art.
    return f"""<!doctype html><html><head><meta charset=utf-8>
<style>html,body{{margin:0;padding:0;background:transparent}}</style></head><body>
<svg width="{size}" height="{size}" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg"><defs>
 <clipPath id="c"><path d="{SHAPE}"/></clipPath>
 <filter id="f" x="-20%" y="-20%" width="140%" height="145%">
   <feDropShadow dx="0" dy="16" stdDeviation="22" flood-color="#000" flood-opacity=".30"/></filter>
</defs>
<g filter="url(#f)"><path d="{SHAPE}" fill="#000"/></g>
<g clip-path="url(#c)">
  <image href="{uri}" x="0" y="0" width="1024" height="1024" preserveAspectRatio="none"/>
</g></svg></body></html>"""


def render(html, dest, px):
    tmp = os.path.join(ROOT, ".cut-tmp.html")
    open(tmp, "w").write(html)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    subprocess.run([CHROME, "--headless", "--disable-gpu",
                    "--default-background-color=00000000",
                    f"--screenshot={dest}", f"--window-size={px},{px}",
                    "--hide-scrollbars", "--virtual-time-budget=3000",
                    "file://" + tmp], capture_output=True)
    os.remove(tmp)
    return os.path.getsize(dest)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    master = sys.argv[1]
    if not os.path.exists(master):
        sys.exit(f"no such master: {master}")
    if not os.path.exists(CHROME):
        sys.exit(f"need Chrome to rasterise: {CHROME}")
    uri = "data:image/png;base64," + base64.b64encode(open(master, "rb").read()).decode()
    print(f"master: {master}")
    for px in SIZES:
        d = os.path.join(ICONSET, f"icon_{px}x{px}.png")
        print(f"  icon_{px}x{px}.png{' '*max(0, 8-len(str(px))*2)}  {render(document(uri, px), d, px):>8,} bytes")
    print(f"  AppLogo/logo.png            {render(document(uri, 1024), LOGO, 1024):>8,} bytes")
    print(f"  design/icon/icon-1024-rounded.png  {render(document(uri, 1024), PREVIEW, 1024):>8,} bytes")


if __name__ == "__main__":
    main()
