#!/bin/bash
# Builds "Picture Viewer.app" next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP="Picture Viewer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Some Command Line Tools installs ship two clashing SwiftBridging modulemaps; hide one via a VFS overlay.
EXTRA=()
if [ -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ] && \
   [ -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap ] && \
   [ "$(xcode-select -p)" = /Library/Developer/CommandLineTools ]; then
  mkdir -p .build-support
  : > .build-support/empty.modulemap
  cat > .build-support/overlay.yaml <<YAML
{"version":0,"roots":[{"name":"/Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap","type":"file","external-contents":"$(pwd)/.build-support/empty.modulemap"}]}
YAML
  EXTRA=(-vfsoverlay .build-support/overlay.yaml)
fi

swiftc -O -swift-version 5 ${EXTRA[@]+"${EXTRA[@]}"} Sources/main.swift -o "$APP/Contents/MacOS/PictureViewer"

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Picture Viewer</string>
  <key>CFBundleDisplayName</key><string>Picture Viewer</string>
  <key>CFBundleIdentifier</key><string>com.local.pictureviewer</string>
  <key>CFBundleExecutable</key><string>PictureViewer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.image</string>
        <string>com.adobe.pdf</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Add :PVBuildDate string $(date '+%Y-%m-%d %H:%M:%S')" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built: $(pwd)/$APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  touch "/Applications/$APP"
  echo "Installed to /Applications/$APP"
fi
