#!/bin/bash
#
# Builds Heatstroke.app — a copy of terminal-notifier with a custom icon
# and bundle ID so macOS notifications appear as "Heatstroke" with a
# thermometer emoji icon.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${SCRIPT_DIR}/Heatstroke.app"
ICONSET_DIR=$(mktemp -d)/Heatstroke.iconset

# Find the terminal-notifier app bundle
TN_APP=$(brew --prefix terminal-notifier 2>/dev/null)/terminal-notifier.app
if [[ ! -d "$TN_APP" ]]; then
  echo "Error: terminal-notifier not found. Install with: brew install terminal-notifier" >&2
  exit 1
fi

# Start fresh
rm -rf "$APP_DIR"
cp -R "$TN_APP" "$APP_DIR"
mkdir -p "$ICONSET_DIR"

# Update Info.plist — change bundle ID and name
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.user.heatstroke.app" "${APP_DIR}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Heatstroke" "${APP_DIR}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "${APP_DIR}/Contents/Info.plist"

# Render the thermometer emoji at each required iconset size via Swift
swift - "$ICONSET_DIR" <<'SWIFT'
import AppKit

let iconsetDir = CommandLine.arguments[1]
let emoji = "🌡️"
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, filename) in sizes {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()

    // Round-rect background
    let bgColor = NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    bgColor.setFill()
    let radius = s * 0.18
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                 xRadius: radius, yRadius: radius).fill()

    // Draw emoji centered
    let fontSize = s * 0.68
    let font = NSFont.systemFont(ofSize: fontSize)
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let str = emoji as NSString
    let textSize = str.size(withAttributes: attrs)
    let x = (s - textSize.width) / 2
    let y = (s - textSize.height) / 2
    str.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)

    img.unlockFocus()

    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        continue
    }
    try! png.write(to: URL(fileURLWithPath: "\(iconsetDir)/\(filename)"))
}
SWIFT

# Convert iconset to icns, replace the old icon
iconutil -c icns -o "${APP_DIR}/Contents/Resources/AppIcon.icns" "$ICONSET_DIR"
# Remove the old Terminal.icns
rm -f "${APP_DIR}/Contents/Resources/Terminal.icns"

rm -rf "$(dirname "$ICONSET_DIR")"

echo "Created ${APP_DIR}"
