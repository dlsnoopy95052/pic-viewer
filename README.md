# Picture Viewer

A small native macOS picture viewer (Swift / AppKit).

- Opens JPEG, PNG, GIF, TIFF, BMP, HEIC, WebP, AVIF, ICO, PSD, SVG, PDF and common RAW formats
- Browse every picture in the same folder with on-screen arrows or ← / →
- Fit / actual size / zoom / pan
- Printing with live preview, paper & orientation selection, shrink-to-fit, fit, actual size, fill, centering

## Build

```bash
./build.sh            # builds "Picture Viewer.app"
./build.sh --install  # also copies it to /Applications
```

Requires the Xcode Command Line Tools (`swiftc`). The app is ad-hoc signed; on first launch right-click → Open.

## License

MIT — see [LICENSE](LICENSE).
