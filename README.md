<img src="assets/icon.svg" width="64" height="64" alt="">

# ClearShot

A fast, open-source screenshot and text-capture tool for macOS. Native Swift, on-device OCR, no account.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/krsambhav/clearshot/main/install.sh | bash
```

Works on any Mac running macOS 15 or later (Apple silicon and Intel). It installs to `/Applications` and launches ClearShot; allow Screen Recording when macOS asks.

## Features

- **Capture text (OCR):** select any area and the text is on your clipboard instantly (Apple Vision, on-device). Also reads QR codes and barcodes.
- **Area, window and fullscreen capture:** the screen freezes on capture; there's a crosshair, Space to switch to window mode, ⇧ for square, ⌥ to draw from the center.
- **Quick Access:** a thumbnail after every capture. Drag it into any app, or hover to copy, save, annotate or pin.
- **Pin to screen:** floating, always-on-top screenshots. Scroll or pinch to zoom, right-click for opacity.
- **Annotate:** arrow, line, rectangle, ellipse, pen, highlighter, text, numbered counters, pixelate/blur, spotlight and crop, plus a background frame for sharing. Edits are non-destructive.
- **History:** every capture is kept locally and is searchable by the text inside it.

| Shortcut | Action |
|---|---|
| ⌥⇧⌘2 | Capture text |
| ⌥⇧⌘3 | Capture fullscreen |
| ⌥⇧⌘4 | Capture area |
| ⌥⇧⌘5 | Capture window |
| ⌥⇧⌘H | Open history |

URL scheme for launchers like Raycast and Alfred: `clearshot://capture-area`, `capture-window`, `capture-fullscreen`, `capture-text`, `history`, `settings`.

## Building

Requires macOS 15+ and Xcode 16+.

```sh
brew install xcodegen
./scripts/setup-signing.sh       # once per Mac: stable local signing so Screen Recording permission survives rebuilds
./scripts/build-and-install.sh   # builds Release, installs to /Applications and launches
```

For development, run `xcodegen generate` and open `ClearShot.xcodeproj`.

## Credits

Set in [Plus Jakarta Sans](https://github.com/tokotype/PlusJakartaSans) (SIL Open Font License). Interface patterns adapted from [shadcn/ui](https://ui.shadcn.com).
