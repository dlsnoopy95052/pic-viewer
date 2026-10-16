# Picture Viewer

A small native macOS picture viewer (Swift / AppKit).

- Opens JPEG, PNG, GIF, TIFF, BMP, HEIC, WebP, AVIF, ICO, PSD, SVG, PDF and common RAW formats
- Browse every picture in the same folder with on-screen arrows or ← / →
- Fit / actual size / zoom / pan
- Rotate left/right (⌘[ / ⌘]), copy to clipboard (⌘C), rename (⌘E), drag & drop to open
- Icon toolbar (top right) for rotate, zoom, fit, slideshow, info, thumbnails, copy, rename, trash
- Annotate: line, arrow, rectangle, circle, freehand pen, text (color + width)
- Simple editing: crop, flip, brightness / contrast / saturation, undo, save or save a copy
- Info panel with file / EXIF details (I), thumbnail strip (T), slideshow (Space)
- Printing with live preview, paper & orientation selection, shrink-to-fit, fit, actual size, fill, centering

## Build

```bash
./build.sh            # builds "Picture Viewer.app"
./build.sh --install  # also copies it to /Applications
```

Requires the Xcode Command Line Tools (`swiftc`). The app is ad-hoc signed; on first launch right-click → Open.

## License

MIT — see [LICENSE](LICENSE).
