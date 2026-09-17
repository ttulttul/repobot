# Repobot app icon

Vector reconstruction of the blue icon in the supplied design image. Includes
the white branching arrow and cyan bars; excludes the wordmark and other text.
The slightly rectangular reference tile is normalized to a square, with rounded
corners and a soft shadow inside a transparent 1024 × 1024 canvas.

- `AppIcon.svg`: editable vector master; no embedded raster images or fonts.
- `AppIcon.iconset/`: the ten required RGBA PNGs with embedded sRGB profiles.
- `AppIcon.icns`: compiled with Apple's `iconutil`.
- `AppIcon-preview.png`: light/dark review sheet with native small sizes and
  nearest-neighbor enlargements for inspecting individual pixels.
- `MenuBarGlyph.svg`: a separate monochrome template glyph, drawn on a 22-point
  transparent canvas with an 18 × 16-point visual footprint. A single black path
  retains the branching arrow, with approximately 2.5-point arms and stem; the
  repository lines are omitted for clarity. Checked at 22 × 22 and 44 × 44 pixels
  (16- and 32-pixel artwork heights) on light and dark backgrounds.

| Filename | Pixels |
| --- | --- |
| icon_16x16.png | 16 × 16 |
| icon_16x16@2x.png | 32 × 32 |
| icon_32x32.png | 32 × 32 |
| icon_32x32@2x.png | 64 × 64 |
| icon_128x128.png | 128 × 128 |
| icon_128x128@2x.png | 256 × 256 |
| icon_256x256.png | 256 × 256 |
| icon_256x256@2x.png | 512 × 512 |
| icon_512x512.png | 512 × 512 |
| icon_512x512@2x.png | 1024 × 1024 |

## Rebuild

From the repository root on macOS, with `uv` installed:

```sh
uv run scripts/build-icons.py
```

The script renders the SVG at 4096 × 4096 using resvg, then derives every size
directly from that render with premultiplied-alpha Lanczos downsampling. This
avoids repeated resizing and prevents transparent-edge color fringes. Python
dependencies are pinned in the script and installed by `uv`.

It checks filenames, dimensions, RGBA mode, transparency, and sRGB profiles,
compiles the ICNS, and extracts it again with `iconutil`. Eight PNG records must
match the exports exactly. Apple's `ic04`/`ic05` ARGB records are checked directly:
alpha is exact and RGB rounding is at most 1/255. Direct checking avoids the
translucent RGB changes introduced when this macOS version extracts those two
records back to PNG.

To compile existing PNGs without rerendering:

```sh
iconutil -c icns assets/icons/AppIcon.iconset -o assets/icons/AppIcon.icns
```

The naming and packaging follow Apple's documented
[high-resolution icon workflow](https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/Optimizing/Optimizing.html).
There is no app target in this checkout yet; these assets are ready to add to its
resources when it is created.
