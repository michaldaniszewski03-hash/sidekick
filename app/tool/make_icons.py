"""Builds every app icon from the logo artwork in website/.

    pip install pillow numpy
    python app/tool/make_icons.py        # from the repo root

Sources:
  website/3.png  the "sk" monogram: every app icon (dock, desktop, taskbar,
                 home screens), at every size
  website/2.png  the SIDEKICK wordmark: the logo inside the app (the website
                 header uses it too)

Writes the Windows .ico, Android launcher icons, macOS and iOS app icon sets,
and the in-app logo. Re-run it whenever the artwork changes.
"""

import io
import json
import struct
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "app"
BG = (204, 197, 255)  # lavender background of the artwork
INK = (42, 28, 86)  # dark purple lettering
# How much of the tile the monogram's longer side covers: enough to read at
# 16 px, with room to breathe so it doesn't look crammed edge to edge.
MONOGRAM_FRAC = 0.56


def load_mask(path: Path) -> Image.Image:
    """Artwork → tightly cropped alpha mask (L mode), anti-aliasing kept."""
    a = np.asarray(Image.open(path).convert("RGB"), float)
    bg, ink = np.array(BG, float), np.array(INK, float)
    t = ((a - bg) @ (ink - bg)) / ((ink - bg) @ (ink - bg))
    alpha = (np.clip(t, 0, 1) * 255).astype(np.uint8)
    ys, xs = np.nonzero(alpha > 8)
    return Image.fromarray(alpha, "L").crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))


WORDMARK = load_mask(ROOT / "website" / "2.png")
MONOGRAM = load_mask(ROOT / "website" / "3.png")


def paste_logo(canvas: Image.Image, box: tuple, *, frac: float = MONOGRAM_FRAC, color=INK) -> None:
    """Centres the "sk" monogram inside `box` (x, y, w, h)."""
    x, y, w, h = box
    mask = MONOGRAM
    scale = min(w * frac / mask.width, h * frac / mask.height)
    m = mask.resize((max(1, round(mask.width * scale)), max(1, round(mask.height * scale))), Image.LANCZOS)
    layer = Image.new("RGBA", m.size, color + (255,))
    layer.putalpha(m)
    canvas.alpha_composite(layer, (x + (w - m.width) // 2, y + (h - m.height) // 2))


def tile(size: int, *, radius_frac: float = 0.0, inset_frac: float = 0.0) -> Image.Image:
    """Lavender (rounded) square with the logo, drawn at 4x then downscaled."""
    s = size * 4
    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    inset = round(s * inset_frac)
    box = (inset, inset, s - 2 * inset, s - 2 * inset)
    shape = Image.new("L", (s, s), 0)
    ImageDraw.Draw(shape).rounded_rectangle(
        (box[0], box[1], box[0] + box[2] - 1, box[1] + box[3] - 1), radius=round(box[2] * radius_frac), fill=255
    )
    fill = Image.new("RGBA", (s, s), BG + (255,))
    canvas.paste(fill, (0, 0), shape)
    paste_logo(canvas, box)
    return canvas.resize((size, size), Image.LANCZOS)


def png_bytes(im: Image.Image) -> bytes:
    buf = io.BytesIO()
    im.save(buf, "PNG", optimize=True)
    return buf.getvalue()


def write_ico(path: Path, images: list) -> None:
    """ICO with PNG-compressed entries, so each size can have its own art."""
    blobs = [png_bytes(im) for im in images]
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries = b""
    for im, blob in zip(images, blobs):
        w = im.width if im.width < 256 else 0
        entries += struct.pack("<BBBBHHII", w, w, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    path.write_bytes(header + entries + b"".join(blobs))


def windows() -> None:
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    write_ico(APP / "windows/runner/resources/app_icon.ico", [tile(s, radius_frac=0.2) for s in sizes])


def android() -> None:
    res = APP / "android/app/src/main/res"
    densities = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for name, k in densities.items():
        folder = res / f"mipmap-{name}"
        folder.mkdir(parents=True, exist_ok=True)
        # Legacy launchers: a rounded square.
        tile(round(48 * k), radius_frac=0.22).save(folder / "ic_launcher.png", optimize=True)
        # Adaptive icon foreground: 108dp canvas; launchers mask it to a
        # 72dp shape and only the 66dp circle is safe. The monogram's corners
        # stay inside it (about the same size as on the other icons).
        px = round(108 * k)
        fg = Image.new("RGBA", (px * 4, px * 4), (0, 0, 0, 0))
        paste_logo(fg, (0, 0, px * 4, px * 4), frac=MONOGRAM_FRAC * 72 / 108)
        fg.resize((px, px), Image.LANCZOS).save(folder / "ic_launcher_foreground.png", optimize=True)
    (res / "values/colors.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        f'    <color name="ic_launcher_background">#FF{BG[0]:02X}{BG[1]:02X}{BG[2]:02X}</color>\n'
        "</resources>\n"
    )
    (res / "mipmap-anydpi-v26").mkdir(exist_ok=True)
    (res / "mipmap-anydpi-v26/ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        "    <!-- Android 13+ themed icons -->\n"
        '    <monochrome android:drawable="@mipmap/ic_launcher_foreground" />\n'
        "</adaptive-icon>\n"
    )


def appiconset(folder: Path, make) -> None:
    contents = json.loads((folder / "Contents.json").read_text())
    done = set()
    for entry in contents["images"]:
        name = entry.get("filename")
        if not name or name in done:
            continue
        points = float(entry["size"].split("x")[0])
        px = round(points * int(entry["scale"].rstrip("x")))
        make(px).save(folder / name, optimize=True)
        done.add(name)


def macos() -> None:
    # Big Sur style: rounded square with a margin, on a transparent canvas.
    appiconset(
        APP / "macos/Runner/Assets.xcassets/AppIcon.appiconset",
        lambda px: tile(px, radius_frac=0.225, inset_frac=0.1),
    )


def ios() -> None:
    # iOS rounds the corners itself and rejects transparency: full-bleed, RGB.
    appiconset(
        APP / "ios/Runner/Assets.xcassets/AppIcon.appiconset",
        lambda px: tile(px).convert("RGB"),
    )


def in_app() -> None:
    """White-on-transparent wordmark; the app tints it with the theme colour."""
    out = APP / "assets/logo"
    out.mkdir(parents=True, exist_ok=True)
    h = 96
    m = WORDMARK.resize((round(WORDMARK.width * h / WORDMARK.height), h), Image.LANCZOS)
    im = Image.new("RGBA", m.size, (255, 255, 255, 255))
    im.putalpha(m)
    im.save(out / "wordmark.png", optimize=True)


if __name__ == "__main__":
    windows()
    android()
    macos()
    ios()
    in_app()
    print("Icons written.")
