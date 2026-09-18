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
The legacy app bundle uses `AppIcon.icns` through `CFBundleIconFile`. The build
compiles the supplied iconset before attempting layered-icon compilation.
`MenuBarGlyph.svg` is loaded at 22 points as an AppKit template image so macOS
adapts it to light, dark, selected and disabled menu-bar appearances.

## Layered icon

`AppIcon.icon` is an editable Icon Composer package for current macOS. It retains
the established branching arrow and six repository lines as two separate vector
groups, above an opaque system-rendered blue background. The vectors have no
baked rounding, bevels, or shadows. Icon Composer supplies the mask, lighting,
shadows, and appearance variants. `AppIcon-layered-preview.png` is an export from
Apple's renderer, not the source used by the app.

Open `AppIcon.icon` in Icon Composer to edit it. The source was validated using
Icon Composer 27's `ictool` renderer in macOS design-generation 26, including
Default, Dark, and TintedDark appearances and a 32-pixel rendering. The Composer
GUI could not be verified because the computer-use connection timed out.

`project.yml` uses this package as the AppIcon resource. `scripts/build-app.sh`
uses `scripts/compile-app-icon.sh` to compile it with Xcode's `actool`. Successful
compilation packages `Assets.car`, merges generated icon metadata, and includes
the compatibility icon Xcode generates for macOS 15. The original ICNS remains
available for builds without a functioning Xcode 26+ asset compiler:

```sh
REPOBOT_LAYERED_ICON=1 ./scripts/build-app.sh  # require the layered icon
REPOBOT_LAYERED_ICON=0 ./scripts/build-app.sh  # original flattened icon
```

The default `auto` mode reports any compiler failure and retains the original
ICNS. It never claims to have built the layered icon on that path. `ACTOOL` can
select a specific compiler; `DEVELOPER_DIR` selects the Xcode developer directory.
The development Mac had Xcode 27 with stale Xcode 16.2 system resources, causing
CoreDevice to fail resolving `_XPCTypeBool` from Mercury. The matching Apple-signed
`XcodeSystemResources.pkg` is bundled in Xcode. Using its extracted frameworks in a
process-local `DYLD_FRAMEWORK_PATH` allowed required-layered compilation to succeed.
The output catalog was inspected with `assetutil`: light, dark, and tinted stacks
each contain three layers, with both vector groups present. Bundle metadata names
`AppIcon`, and deep/strict signing verification passed. The generated compatibility
ICNS was also extracted and visually inspected. The user subsequently installed the
signed package system-wide; its receipt now reports `27.0.0.0.1788430725`. Required-layered
compilation, catalog inspection, and signing verification all passed again with no
framework overrides and with the toolchain fallback disabled. Finder/Dock presentation
is not yet verified.

This follows Apple's [Icon Composer workflow](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
and [app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons).
Apple's generated compatibility icon differs from the preserved original ICNS;
select mode `0` when the original appearance is required on every macOS version.
