#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow==12.1.1", "resvg-py==0.2.6"]
# ///
"""Render the vector icon at 4x, downsample, and compile the macOS icon pack.

Run: uv run scripts/build-icons.py
Requires macOS iconutil for the final .icns compilation.
"""

from io import BytesIO
from pathlib import Path
import json
import shutil
import struct
import subprocess
import tempfile

from PIL import Image, ImageCms, ImageDraw
import resvg_py


ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "assets" / "icons"
ICONSET = DEST / "AppIcon.iconset"
SIZES = {
    f"icon_{points}x{points}{suffix}.png": points * scale
    for points in (16, 32, 128, 256, 512)
    for suffix, scale in (("", 1), ("@2x", 2))
}
PROFILE = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()


def save_png(image, path):
    image.save(path, icc_profile=PROFILE, optimize=True)


def preview(images):
    """Show native pixel sizes and nearest-neighbor enlargements on two surfaces."""
    sheet = Image.new("RGB", (1440, 1030), "#eef2f7")
    draw = ImageDraw.Draw(sheet)
    draw.text((28, 18), "REPOBOT / VECTOR ICON EXPORT REVIEW", fill="#20334d", font_size=22)
    for x, bg, fg in ((20, "#ffffff", "#29405b"), (730, "#172332", "#d8e8fa")):
        draw.rounded_rectangle((x, 60, x + 690, 780), radius=16, fill=bg)
        sheet.paste(images[512], (x + 89, 76), images[512])
        draw.text((x + 22, 597), "Native pixels: 16 / 32 / 64 / 128", fill=fg, font_size=18)
        for size, dx in ((16, 32), (32, 92), (64, 176), (128, 306)):
            im = images[size]
            sheet.paste(im, (x + dx, 636), im)
    draw.text((28, 802), "Small exports enlarged 6x with nearest-neighbor sampling (pixel inspection)", fill="#29405b", font_size=18)
    for size, x in ((16, 28), (32, 176)):
        enlarged = images[size].resize((size * 6, size * 6), Image.Resampling.NEAREST)
        sheet.paste(enlarged, (x, 839), enlarged)
    draw.text((420, 864), "1024 px square canvas / transparent RGBA / embedded sRGB", fill="#29405b", font_size=20)
    draw.text((420, 902), "4096 px SVG render / premultiplied-alpha Lanczos downsampling", fill="#29405b", font_size=20)
    save_png(sheet, DEST / "AppIcon-preview.png")


def verify_small_argb(path, images):
    """Inspect Apple's small-icon ARGB records before its decoder unpremultiplies.

    iconutil's extraction changes translucent RGB in ic04/ic05 records on this
    macOS release. Check the stored channels instead; its encoder rounds RGB by
    at most one 8-bit level. Alpha must remain exact.
    """
    data = path.read_bytes()
    assert data[:4] == b"icns" and struct.unpack(">I", data[4:8])[0] == len(data)
    cursor = 8
    checked = set()
    while cursor < len(data):
        kind, length = struct.unpack(">4sI", data[cursor:cursor + 8])
        assert length >= 8 and cursor + length <= len(data)
        payload = data[cursor + 8:cursor + length]
        cursor += length
        if kind not in (b"ic04", b"ic05"):
            continue
        size = 16 if kind == b"ic04" else 32
        assert payload[:4] == b"ARGB"
        decoded = bytearray()
        index = 4
        while index < len(payload):
            control = payload[index]
            index += 1
            if control < 128:
                count = control + 1
                decoded.extend(payload[index:index + count])
                index += count
            else:
                decoded.extend([payload[index]] * (control - 125))
                index += 1
        pixels = size * size
        assert len(decoded) == pixels * 4
        for channel_index, channel in enumerate("ARGB"):
            stored = decoded[channel_index * pixels:(channel_index + 1) * pixels]
            original = images[size].getchannel(channel).tobytes()
            tolerance = 0 if channel == "A" else 1
            assert max(abs(a - b) for a, b in zip(stored, original)) <= tolerance
        checked.add(size)
    return checked


def main():
    if not shutil.which("iconutil"):
        raise SystemExit("macOS iconutil is required to compile and verify AppIcon.icns")
    ICONSET.mkdir(parents=True, exist_ok=True)
    png = resvg_py.svg_to_bytes(svg_path=str(DEST / "AppIcon.svg"), width=4096, height=4096)
    # Filter premultiplied color and alpha together so transparent edges do not
    # acquire black or white fringes. Every size comes directly from the render.
    master = Image.open(BytesIO(png)).convert("RGBA").convert("RGBa")
    images = {
        size: master.resize((size, size), Image.Resampling.LANCZOS).convert("RGBA")
        for size in sorted(set(SIZES.values()))
    }
    for filename, size in SIZES.items():
        save_png(images[size], ICONSET / filename)
    assert {p.name for p in ICONSET.iterdir()} == set(SIZES), "Unexpected iconset files"
    for filename, size in SIZES.items():
        with Image.open(ICONSET / filename) as image:
            assert image.size == (size, size), filename
            assert image.mode == "RGBA", filename
            assert image.getextrema()[3] == (0, 255), filename
            assert image.getpixel((0, 0))[3] == 0, filename
            assert image.info.get("icc_profile") == PROFILE, filename
    output = DEST / "AppIcon.icns"
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(output)], check=True)
    small_argb = verify_small_argb(output, images)
    # Decode the compiled artifact with Apple's tool and check actual pixels.
    with tempfile.TemporaryDirectory(prefix="repobot-icons-") as temp:
        decoded = Path(temp) / "Decoded.iconset"
        subprocess.run(["iconutil", "-c", "iconset", str(output), "-o", str(decoded)], check=True)
        assert {p.name for p in decoded.iterdir()} == set(SIZES), "ICNS slot mismatch"
        for filename, size in SIZES.items():
            with Image.open(decoded / filename) as image:
                assert image.size == (size, size), filename
                if filename in ("icon_16x16.png", "icon_32x32.png") and size in small_argb:
                    assert image.convert("RGBA").getchannel("A").tobytes() == images[size].getchannel("A").tobytes(), filename
                else:
                    assert image.convert("RGBA").tobytes() == images[size].tobytes(), filename
    preview(images)
    print(json.dumps({"iconset": str(ICONSET), "icns": str(output), "verified_sizes": SIZES, "icns_verification": "PNG records pixel-exact; small ARGB records alpha-exact, RGB within 1/255"}, indent=2))


if __name__ == "__main__":
    main()
