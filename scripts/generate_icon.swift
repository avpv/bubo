#!/usr/bin/env swift
// Generates AppIcon.icns for CalendarReminder
// Usage: swift scripts/generate_icon.swift

import AppKit

let sizes: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

let iconsetPath = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for (size, name) in sizes {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()

    // Blue rounded background
    let bgPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                              xRadius: s * 0.16, yRadius: s * 0.16)
    NSColor(red: 0.10, green: 0.45, blue: 0.91, alpha: 1).setFill()
    bgPath.fill()

    // White calendar body
    let bodyPath = NSBezierPath(roundedRect: NSRect(x: s*0.11, y: s*0.07, width: s*0.78, height: s*0.62),
                                xRadius: s*0.06, yRadius: s*0.06)
    NSColor.white.setFill()
    bodyPath.fill()

    // Dark blue calendar header
    let headerPath = NSBezierPath(roundedRect: NSRect(x: s*0.11, y: s*0.55, width: s*0.78, height: s*0.23),
                                  xRadius: s*0.06, yRadius: s*0.06)
    NSColor(red: 0.08, green: 0.34, blue: 0.69, alpha: 1).setFill()
    headerPath.fill()

    // Calendar pins
    for xPos in [s * 0.28, s * 0.68] {
        let pin = NSBezierPath(roundedRect: NSRect(x: xPos - s*0.02, y: s*0.65, width: s*0.05, height: s*0.14),
                               xRadius: s*0.02, yRadius: s*0.02)
        NSColor.white.setFill()
        pin.fill()
    }

    // Letter "C" on calendar
    let font = NSFont.boldSystemFont(ofSize: s * 0.35)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(red: 0.10, green: 0.45, blue: 0.91, alpha: 1),
    ]
    let str = NSAttributedString(string: "C", attributes: attrs)
    let strSize = str.size()
    str.draw(at: NSPoint(x: (s - strSize.width) / 2, y: s * 0.12))

    img.unlockFocus()

    if let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try png.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name)"))
    }
}

// Convert iconset to icns
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetPath, "-o", "CalendarReminder/Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()

// Cleanup
try? FileManager.default.removeItem(atPath: iconsetPath)

if task.terminationStatus == 0 {
    print("✓ Created CalendarReminder/Resources/AppIcon.icns")
} else {
    print("✗ iconutil failed with status \(task.terminationStatus)")
    exit(1)
}
