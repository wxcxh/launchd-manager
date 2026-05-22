#!/usr/bin/env python3

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "assets" / "LaunchdManager.iconset"
MASTER = ROOT / "assets" / "launchd-manager-icon-1024.png"


def rounded_rectangle_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def build_master_icon(size=1024):
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    top = (245, 178, 97)
    bottom = (203, 89, 63)
    for y in range(size):
        t = y / max(size - 1, 1)
        r = int(top[0] * (1 - t) + bottom[0] * t)
        g = int(top[1] * (1 - t) + bottom[1] * t)
        b = int(top[2] * (1 - t) + bottom[2] * t)
        draw.line((0, y, size, y), fill=(r, g, b, 255))

    mask = rounded_rectangle_mask(size, int(size * 0.22))
    clipped = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    clipped.paste(image, mask=mask)
    image = clipped
    draw = ImageDraw.Draw(image)

    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    panel = (
        int(size * 0.17),
        int(size * 0.18),
        int(size * 0.83),
        int(size * 0.80),
    )
    shadow_draw.rounded_rectangle(panel, radius=int(size * 0.08), fill=(0, 0, 0, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=int(size * 0.03)))
    image.alpha_composite(shadow, dest=(0, int(size * 0.018)))

    panel_fill = (255, 248, 238, 255)
    panel_outline = (120, 68, 56, 60)
    draw.rounded_rectangle(panel, radius=int(size * 0.08), fill=panel_fill, outline=panel_outline, width=3)

    # Header strip
    header = (
        panel[0],
        panel[1],
        panel[2],
        panel[1] + int(size * 0.13),
    )
    draw.rounded_rectangle(header, radius=int(size * 0.08), fill=(122, 59, 50, 255))
    draw.rectangle((header[0], header[3] - int(size * 0.05), header[2], header[3]), fill=(122, 59, 50, 255))

    # Rows
    row_left = panel[0] + int(size * 0.07)
    row_right = panel[2] - int(size * 0.07)
    row_y = panel[1] + int(size * 0.21)
    row_gap = int(size * 0.12)
    row_height = int(size * 0.065)
    accent = (231, 128, 95, 255)
    text = (95, 65, 57, 255)
    muted = (196, 167, 154, 255)

    for idx in range(3):
        y0 = row_y + idx * row_gap
        dot_box = (row_left, y0, row_left + row_height, y0 + row_height)
        draw.rounded_rectangle(dot_box, radius=int(row_height * 0.35), fill=accent if idx == 0 else muted)
        line_y = y0 + row_height / 2
        draw.rounded_rectangle(
            (row_left + int(size * 0.10), line_y - 10, row_right, line_y + 10),
            radius=10,
            fill=text if idx == 0 else muted,
        )

    # Clock badge
    badge_size = int(size * 0.26)
    badge_x = panel[2] - badge_size - int(size * 0.04)
    badge_y = panel[1] - int(size * 0.06)
    draw.ellipse((badge_x, badge_y, badge_x + badge_size, badge_y + badge_size), fill=(255, 241, 225, 255))
    draw.ellipse(
        (badge_x + 8, badge_y + 8, badge_x + badge_size - 8, badge_y + badge_size - 8),
        outline=(170, 95, 72, 255),
        width=int(size * 0.012),
    )
    center_x = badge_x + badge_size / 2
    center_y = badge_y + badge_size / 2
    draw.line(
        (center_x, center_y, center_x, badge_y + badge_size * 0.28),
        fill=(170, 95, 72, 255),
        width=int(size * 0.014),
    )
    draw.line(
        (center_x, center_y, badge_x + badge_size * 0.72, center_y),
        fill=(170, 95, 72, 255),
        width=int(size * 0.014),
    )
    draw.ellipse(
        (center_x - 14, center_y - 14, center_x + 14, center_y + 14),
        fill=(170, 95, 72, 255),
    )

    # Small "ld" monogram
    font_candidates = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ]
    font = None
    for candidate in font_candidates:
        path = Path(candidate)
        if path.exists():
            font = ImageFont.truetype(str(path), int(size * 0.10))
            break
    if font is not None:
        draw.text(
            (panel[0] + int(size * 0.08), panel[1] + int(size * 0.045)),
            "ld",
            font=font,
            fill=(255, 247, 242, 255),
        )

    MASTER.parent.mkdir(parents=True, exist_ok=True)
    image.save(MASTER)
    return image


def export_iconset(image):
    ICONSET.mkdir(parents=True, exist_ok=True)
    sizes = [16, 32, 128, 256, 512]
    for size in sizes:
        image.resize((size, size), Image.LANCZOS).save(ICONSET / f"icon_{size}x{size}.png")
        image.resize((size * 2, size * 2), Image.LANCZOS).save(ICONSET / f"icon_{size}x{size}@2x.png")


def main():
    image = build_master_icon()
    export_iconset(image)
    print(f"generated {MASTER}")


if __name__ == "__main__":
    main()
