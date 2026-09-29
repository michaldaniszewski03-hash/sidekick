"""Builds every app icon from the logo artwork in website/.

    pip install pillow numpy
    python app/tool/make_icons.py        # from the repo root

Source:
  website/3.png  the "sk" monogram: every app icon (dock, desktop, taskbar,
                 home screens) at every size, and the logo inside the app.
                 (The website uses the SIDEKICK wordmark, website/2.png,
                 embedded in index.html.)

Writes the Windows .ico, Android launcher icons, macOS and iOS app icon sets,
and the in-app logo. Re-run it whenever the artwork changes.

Mac and iPhone get the Liquid Glass look:
  * AppIcon.icon (Icon Composer format) in ios/Runner and macos/Runner: a
    lavender gradient with the "sk" as a glass layer. On macOS/iOS 26 and
    later the system renders it as real Liquid Glass (live highlights,
    depth, and the Dark, Clear and Tinted looks). Xcode 26 builds it.
  * The AppIcon.appiconset images are a pre-rendered glass version of the
    same, for older macOS and iOS.
"""

import io
import json
import shutil
import struct
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

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


# ------------------------------------------------------------ Liquid Glass

GLASS_TOP = (222, 216, 255)  # light lavender at the top of the tile
GLASS_BOTTOM = (160, 145, 250)  # deeper at the bottom
INK_TOP = (78, 60, 150)  # the glyph is lighter where light hits it
INK_BOTTOM = (34, 22, 74)


def _vertical(size: int, top: tuple, bottom: tuple) -> Image.Image:
    t = np.linspace(0, 1, size)[:, None, None]
    rows = np.array(top, float) * (1 - t) + np.array(bottom, float) * t
    return Image.fromarray(np.repeat(rows, size, axis=1).astype(np.uint8), "RGB").convert("RGBA")


def _glyph_mask(s: int, frac: float) -> Image.Image:
    """The monogram's alpha, centred on an s×s canvas."""
    scale = min(s * frac / MONOGRAM.width, s * frac / MONOGRAM.height)
    m = MONOGRAM.resize((round(MONOGRAM.width * scale), round(MONOGRAM.height * scale)), Image.LANCZOS)
    out = Image.new("L", (s, s), 0)
    out.paste(m, ((s - m.width) // 2, (s - m.height) // 2))
    return out


def glass_tile(size: int, *, radius_frac: float = 0.0, inset_frac: float = 0.0, full_bleed: bool = False) -> Image.Image:
    """A pre-rendered Liquid Glass icon: frosted lavender, a soft sheen and
    rim light, and a glossy "sk" with depth. Drawn at 4x, then downscaled."""
    s = size * 4
    inset = round(s * inset_frac)
    w = s - 2 * inset
    shape = Image.new("L", (s, s), 0)
    ImageDraw.Draw(shape).rounded_rectangle((inset, inset, inset + w - 1, inset + w - 1), radius=round(w * radius_frac), fill=255)

    tile = _vertical(s, GLASS_TOP, GLASS_BOTTOM)
    # A broad sheen from the top left, like light through glass.
    sheen = Image.new("L", (s, s), 0)
    ImageDraw.Draw(sheen).ellipse((inset - w * 0.35, inset - w * 0.6, inset + w * 0.95, inset + w * 0.45), fill=120)
    sheen = sheen.filter(ImageFilter.GaussianBlur(w * 0.08))
    tile = Image.composite(Image.new("RGBA", (s, s), (255, 255, 255, 255)), tile, sheen)

    # The glyph: a soft shadow under it, a vertical gradient in it, and a
    # bright edge along its top where the light catches.
    glyph = _glyph_mask(s, MONOGRAM_FRAC * (w / s))
    shadow = ImageChops.offset(glyph, 0, round(w * 0.025)).filter(ImageFilter.GaussianBlur(w * 0.022))
    tile = Image.composite(Image.new("RGBA", (s, s), INK_BOTTOM + (255,)), tile, shadow.point(lambda v: v * 0.35))
    ink = _vertical(s, INK_TOP, INK_BOTTOM)
    tile = Image.composite(ink, tile, glyph)
    below = ImageChops.offset(glyph, 0, round(w * 0.008))
    edge = ImageChops.subtract(glyph, below).filter(ImageFilter.GaussianBlur(w * 0.002))
    tile = Image.composite(Image.new("RGBA", (s, s), (255, 255, 255, 255)), tile, edge.point(lambda v: v * 0.55))
    # Inner gloss on the upper half of the glyph.
    upper = Image.new("L", (s, s), 0)
    ImageDraw.Draw(upper).rectangle((0, 0, s, s * 0.47), fill=70)
    upper = upper.filter(ImageFilter.GaussianBlur(w * 0.03))
    tile = Image.composite(Image.new("RGBA", (s, s), (255, 255, 255, 255)), tile, ImageChops.multiply(glyph, upper))

    # Rim light: a thin bright line around the tile, strongest at the top.
    ring = ImageChops.subtract(shape, shape.filter(ImageFilter.MinFilter(max(3, (round(w * 0.012) // 2) * 2 + 1))))
    fade = _vertical(s, (255, 255, 255), (90, 90, 90)).convert("L")
    tile = Image.composite(Image.new("RGBA", (s, s), (255, 255, 255, 255)), tile, ImageChops.multiply(ring, fade).point(lambda v: v * 0.7))

    out = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    if full_bleed:
        out = tile
    else:
        out.paste(tile, (0, 0), shape)
    return out.resize((size, size), Image.LANCZOS)


def icon_composer() -> None:
    """AppIcon.icon for Xcode 26: the system turns it into Liquid Glass."""
    canvas = 1024
    glyph = _glyph_mask(canvas * 4, MONOGRAM_FRAC).resize((canvas, canvas), Image.LANCZOS)
    layer = Image.new("RGBA", (canvas, canvas), INK + (255,))
    layer.putalpha(glyph)

    def srgb(c: tuple) -> str:
        return "srgb:" + ",".join(f"{v / 255:.5f}" for v in c) + ",1.00000"

    spec = {
        "fill": {"linear-gradient": [srgb(GLASS_TOP), srgb(GLASS_BOTTOM)]},
        "groups": [
            {
                "layers": [{"glass": True, "image-name": "sk.png", "name": "sk"}],
                "shadow": {"kind": "layer-color", "opacity": 0.5},
                "translucency": {"enabled": True, "value": 0.4},
            }
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    for platform in ("ios", "macos"):
        folder = APP / platform / "Runner/AppIcon.icon"
        shutil.rmtree(folder, ignore_errors=True)
        (folder / "Assets").mkdir(parents=True)
        layer.save(folder / "Assets/sk.png", optimize=True)
        (folder / "icon.json").write_text(json.dumps(spec, indent=2) + "\n")


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
    # Before macOS 26: a rounded square with a margin, on a transparent canvas.
    appiconset(
        APP / "macos/Runner/Assets.xcassets/AppIcon.appiconset",
        lambda px: glass_tile(px, radius_frac=0.225, inset_frac=0.1),
    )


def ios() -> None:
    # Before iOS 26. iOS rounds the corners itself and rejects transparency:
    # full-bleed, RGB.
    appiconset(
        APP / "ios/Runner/Assets.xcassets/AppIcon.appiconset",
        lambda px: glass_tile(px, full_bleed=True).convert("RGB"),
    )


def in_app() -> None:
    """White-on-transparent "sk"; the app tints it with the theme colour."""
    out = APP / "assets/logo"
    out.mkdir(parents=True, exist_ok=True)
    h = 192  # sharp at 3x on a 64 px logo
    m = MONOGRAM.resize((round(MONOGRAM.width * h / MONOGRAM.height), h), Image.LANCZOS)
    im = Image.new("RGBA", m.size, (255, 255, 255, 255))
    im.putalpha(m)
    im.save(out / "logo.png", optimize=True)
    (out / "wordmark.png").unlink(missing_ok=True)


if __name__ == "__main__":
    windows()
    android()
    macos()
    ios()
    icon_composer()
    in_app()
    print("Icons written.")
