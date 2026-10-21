# Picture Viewer

A small native macOS picture viewer with light annotation and editing, written in Swift / AppKit as a single source file with no third-party dependencies.

<!-- Add a screenshot here, e.g. ![Picture Viewer](docs/screenshot.png) -->

## Features

- Opens JPEG, PNG, GIF, TIFF, BMP, HEIC, WebP, AVIF, ICO, PSD, SVG, PDF and common RAW formats
- Browse every picture in the same folder with on-screen arrows or ← / →; drag & drop to open
- Fit / actual size / zoom / pan
- Capture a screen area with the global hot key ⌥⌘4 (works while another app is in front); the capture opens right here to annotate and edit, and is also copied to the clipboard (toggle in the File menu). Needs Screen Recording permission on first use
- Icon toolbar (top right) for capture, rotate, zoom, fit, slideshow, info, thumbnails, copy, paste, rename, trash
- Info panel with file / EXIF details, thumbnail strip, slideshow
- Printing with live preview, paper & orientation selection, shrink-to-fit, fit, actual size, fill, centering

### Annotate

Annotations stay editable until the picture is flattened.

- Tools: line, arrow, rectangle, circle, freehand pen, text, and **Mosaic** to pixelate sensitive areas
- Click to select, drag to move, drag end points to resize, change color / width of the selection, Delete to remove
- Drag the round knob to rotate rectangles, circles and text (Shift = 15° steps)
- Double-click text to edit (multi-line); drag the right-edge handle to wrap text; pick font, bold, italic and background color
- Paste (⌘V) a picture from the clipboard as a layer you can move, resize and rotate

### Edit

Editing changes the picture's pixels, so it flattens any annotations first.

- Crop, flip horizontally / vertically, brightness / contrast / saturation
- Undo, save, or save a copy

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Open | ⌘O |
| Capture screen area (global) | ⌥⌘4 |
| Save / Save a Copy | ⌘S / ⇧⌘S |
| Print / Page Setup | ⌘P / ⇧⌘P |
| Rename | ⌘E |
| Show in Finder | ⌘R |
| Move to Trash | ⌘⌫ |
| Close | ⌘W |
| Undo | ⌘Z |
| Copy / Paste | ⌘C / ⌘V |
| Crop | ⌘K |
| Previous / next picture | ← / → |
| First / last picture | Home / End |
| Fit to window / actual size | ⌘0 / ⌘1 |
| Zoom in / out | ⌘+ / ⌘- |
| Rotate left / right | ⌘[ / ⌘] |
| Info panel | ⌘I |
| Thumbnail strip | ⌘T |
| Slideshow | Space |
| Full screen | ⌃⌘F |

## Requirements

- macOS 12.0 or later
- Xcode Command Line Tools (`swiftc`) to build

## Build

```bash
./build.sh            # builds "Picture Viewer.app"
./build.sh --install  # also copies it to /Applications
```

### Code signing

If a code-signing certificate named `PictureViewer Local Signing` exists in your Keychain, `build.sh` signs the app with it, so macOS keeps privacy permissions across rebuilds. Create one in Keychain Access → Certificate Assistant → Create a Certificate (type: Code Signing).

Otherwise the app is ad-hoc signed: privacy permissions may reset on every rebuild, and on first launch you need to right-click → Open.

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/main.swift` | The whole app |
| `build.sh` | Builds, bundles, signs and optionally installs the app |
| `Resources/AppIcon.icns` | App icon |
| `tools/make-icon.swift` | Script that generates the app icon |
| `GLOSSARY.md` | Domain terms (Picture, Annotation, Mosaic, Pasted layer, Flatten, View rotation, Annotate, Edit) |
| `docs/agents/` | Issue tracker, triage labels and domain-doc setup for coding agents |

## Contributing

Issues are tracked in GitHub Issues. Use the terms in [GLOSSARY.md](GLOSSARY.md) when describing behavior.

## License

MIT — see [LICENSE](LICENSE).
