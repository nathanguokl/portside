#!/usr/bin/env swift
import Foundation

// Run with `swift scripts/make-icon.swift` to package the supplied branding
// assets. The checked-in ICNS is the original supplied file; regeneration is
// optional and uses the same PNGs without redrawing or resizing the artwork.
let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let repositoryURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let packagingURL = repositoryURL.appendingPathComponent("packaging/macos", isDirectory: true)
let sourceURL = packagingURL.appendingPathComponent("Portside.appiconset", isDirectory: true)
let outputURL = packagingURL.appendingPathComponent("Portside.icns")
let temporaryURL = fileManager.temporaryDirectory.appendingPathComponent("portside-icon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = temporaryURL.appendingPathComponent("Portside.iconset", isDirectory: true)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: temporaryURL) }

// iconutil expects an .iconset directory with standard PNG filenames, without
// the asset catalog's Contents.json. Copy each required resolution unchanged.
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@2x"
        let filename = "icon_\(size)x\(size)\(suffix).png"
        try fileManager.copyItem(at: sourceURL.appendingPathComponent(filename),
                                 to: iconsetURL.appendingPathComponent(filename))
    }
}

let generatedURL = temporaryURL.appendingPathComponent("Portside.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", generatedURL.path, iconsetURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    throw NSError(domain: "PortsideIcon", code: Int(iconutil.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil could not package the supplied app icon. Check packaging/macos/Portside.appiconset."])
}
try Data(contentsOf: generatedURL).write(to: outputURL, options: .atomic)
print("Packaged supplied branding: \(outputURL.path)")
