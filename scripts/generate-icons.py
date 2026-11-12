"""Generate Unbound Muzik PWA icons from the favicon.svg artwork (redrawn exactly).

Runs at build time (GitHub Actions) so no binary icon files are committed —
the connector cannot push binary files, and the app token cannot create
workflow files, so icons are generated here instead of uploaded.

Artwork (viewBox 512): void #050505 rounded-square background (rx 112),
violet->sky diagonal gradient ring (centre 256,256, r 150, stroke 34),
white vertical bar (256,176)-(256,336), width 34, round caps,
mint dot (256,336, r 20). The gradient uses the ring's bounding box,
matching the SVG's objectBoundingBox gradient.
"""
from pathlib import Path

from PIL import Image, ImageDraw
import numpy as np

S = 512
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "public"

violet = np.array([0x8B, 0x5C, 0xF6], dtype=np.float64)
sky = np.array([0x38, 0xBD, 0xF8], dtype=np.float64)

yy, xx = np.mgrid[0:S, 0:S].astype(np.float64)
# Gradient across the ring's bbox (106..406), as the SVG does.
t = np.clip(((xx - 106) + (yy - 106)) / 600.0, 0, 1)
grad = (violet * (1 - t[..., None]) + sky * t[..., None]).astype(np.uint8)

dist_c = np.sqrt((xx - 256) ** 2 + (yy - 256) ** 2)
ring = (dist_c >= 133) & (dist_c <= 167)
bar = (
    ((np.abs(xx - 256) <= 17) & (yy >= 176) & (yy <= 336))
    | (np.sqrt((xx - 256) ** 2 + (yy - 176) ** 2) <= 17)
    | (np.sqrt((xx - 256) ** 2 + (yy - 336) ** 2) <= 17)
)
dot = np.sqrt((xx - 256) ** 2 + (yy - 336) ** 2) <= 20

VOID = np.array([5, 5, 5], dtype=np.uint8)
WHITE = np.array([250, 250, 250], dtype=np.uint8)
MINT = np.array([0x34, 0xD3, 0x99], dtype=np.uint8)


def build(maskable: bool) -> Image.Image:
    rgb = np.zeros((S, S, 3), dtype=np.uint8)
    alpha = np.zeros((S, S), dtype=np.uint8)
    if maskable:
        rgb[:, :] = VOID
        alpha[:, :] = 255
    else:
        m = Image.new("L", (S, S), 0)
        ImageDraw.Draw(m).rounded_rectangle([0, 0, S - 1, S - 1], radius=112, fill=255)
        bg = np.array(m) > 0
        rgb[bg] = VOID
        alpha[bg] = 255
    rgb[ring] = grad[ring]
    alpha[ring] = 255
    rgb[bar] = WHITE
    alpha[bar] = 255
    rgb[dot] = MINT
    alpha[dot] = 255
    return Image.fromarray(np.dstack([rgb, alpha]), "RGBA")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    any512 = build(False)
    any512.save(OUT / "icon-512.png")
    any512.resize((192, 192), Image.LANCZOS).save(OUT / "icon-192.png")
    build(True).save(OUT / "icon-512-maskable.png")
    print("icons written to", OUT)


if __name__ == "__main__":
    main()
