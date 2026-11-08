"""Builds the HCG app icons and in-app marks for Distil, Relay and Presentation Studio
from docs/assets/hcg/hcg-logo.webp (the HCG logo as supplied, 1933 x 814).

The icon follows the macOS app icon grid: a 824 x 824 rounded square (corner radius 185)
centred on a transparent 1024 x 1024 canvas. The logo sits across the middle of a black
body; its own background is near-black, so the top and bottom of the logo strip are faded
into the body instead of leaving visible edges.

Usage (from the repository root): python3 docs/assets/hcg/make_hcg_assets.py
Needs Pillow (writes .icns on any platform).
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[3]
SRC = Path(__file__).with_name("hcg-logo.webp")

CANVAS, BODY, RADIUS = 1024, 824, 185
OFFSET = (CANVAS - BODY) // 2


def app_icon() -> Image.Image:
    logo = Image.open(SRC).convert("RGB")
    # Keep the flares, drop the outermost black margin.
    logo = logo.crop((60, 40, logo.width - 60, logo.height))
    width = BODY + 40  # slightly wider than the body so the flares run off its edges
    height = round(logo.height * width / logo.width)
    logo = logo.resize((width, height), Image.LANCZOS)

    # Fade the strip's top and bottom into the body.
    fade = 60
    mask = Image.new("L", logo.size, 255)
    draw = ImageDraw.Draw(mask)
    for y in range(fade):
        a = round(255 * (y / fade) ** 1.5)
        draw.line([(0, y), (width, y)], fill=a)
        draw.line([(0, height - 1 - y), (width, height - 1 - y)], fill=a)

    body = Image.new("RGB", (BODY, BODY), (0, 0, 0))
    # A faint blue floor glow under the letters, like the source artwork.
    glow = Image.new("L", (BODY, BODY), 0)
    ImageDraw.Draw(glow).ellipse((90, BODY // 2 + 40, BODY - 90, BODY // 2 + 260), fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(60))
    body.paste(Image.new("RGB", body.size, (10, 70, 140)), (0, 0), glow)
    body.paste(logo, ((BODY - width) // 2, (BODY - height) // 2), mask)

    shape = Image.new("L", (BODY, BODY), 0)
    ImageDraw.Draw(shape).rounded_rectangle((0, 0, BODY - 1, BODY - 1), RADIUS, fill=255)
    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    icon.paste(body, (OFFSET, OFFSET), shape)
    # Hairline rim so the icon keeps its shape on a black Dock or window.
    rim = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle((OFFSET, OFFSET, OFFSET + BODY - 1, OFFSET + BODY - 1), RADIUS,
                                          outline=(120, 190, 255, 70), width=4)
    return Image.alpha_composite(icon, rim)


def mark(icon: Image.Image, size: int) -> Image.Image:
    """The rounded square without the transparent margin, for use inside the apps."""
    body = icon.crop((OFFSET, OFFSET, OFFSET + BODY, OFFSET + BODY))
    return body.resize((size, size), Image.LANCZOS)


def save_icns(icon: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    icon.save(path, format="ICNS", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])


def main() -> None:
    icon = app_icon()
    out = Path(__file__).parent
    icon.save(out / "hcg-app-icon-1024.png", optimize=True)

    for product in ("distil", "relay"):
        res = ROOT / product / "Resources"
        save_icns(icon, res / "AppIcon.icns")
        mark(icon, 128).save(res / "HCGMark.png", optimize=True)

    ps = ROOT / "presentation-studio"
    save_icns(icon, ps / "desktop" / "resources" / "icon.icns")
    icon.save(ps / "desktop" / "resources" / "icon.png", optimize=True)
    (ps / "public").mkdir(exist_ok=True)
    mark(icon, 128).save(ps / "public" / "hcg-mark.png", optimize=True)
    mark(icon, 64).save(ps / "public" / "favicon.png", optimize=True)
    print("Wrote icons for distil, relay and presentation-studio.")


if __name__ == "__main__":
    main()
