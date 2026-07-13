#!/usr/bin/env swift
import AppKit
import CoreGraphics
import CoreImage

let repo    = FileManager.default.currentDirectoryPath
let srcPath = "\(repo)/scripts/assets/pancham-logo-master.png"
let outDir  = "\(repo)/Pancham/Assets.xcassets/AppIcon.appiconset"

guard let srcData = try? Data(contentsOf: URL(fileURLWithPath: srcPath)),
      let srcImg  = NSBitmapImageRep(data: srcData)?.cgImage else {
    fatalError("Could not load source logo at \(srcPath)")
}

func color(_ hex: UInt32) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >>  8) & 0xFF) / 255
    let b = CGFloat( hex        & 0xFF) / 255
    return CGColor(red: r, green: g, blue: b, alpha: 1)
}
let paper = color(0xF4EFE6)

func renderMaster(size: CGFloat = 1024) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil,
                        width: Int(size), height: Int(size),
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // Rounded paper tile — matches macOS squircle mask.
    let corner = size * 0.2237
    let tile = CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                      cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.addPath(tile)
    ctx.setFillColor(paper)
    ctx.fillPath()

    // Place logo centered with ~13% inset (logo's own whitespace already adds air).
    let inset: CGFloat = size * 0.08
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    ctx.draw(srcImg, in: rect)
    return ctx.makeImage()!
}

func downsample(_ master: CGImage, to px: Int) -> CGImage {
    guard px != master.width else { return master }
    let ci = CIImage(cgImage: master)
    let f = CIFilter(name: "CILanczosScaleTransform")!
    f.setValue(ci, forKey: kCIInputImageKey)
    f.setValue(CGFloat(px) / CGFloat(master.width), forKey: kCIInputScaleKey)
    f.setValue(1.0, forKey: kCIInputAspectRatioKey)
    let ctx = CIContext(options: [.useSoftwareRenderer: false])
    return ctx.createCGImage(f.outputImage!, from: CGRect(x: 0, y: 0, width: px, height: px))!
}

func writePNG(_ img: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    let data = rep.representation(using: .png, properties: [.interlaced: false])!
    try! data.write(to: URL(fileURLWithPath: path))
}

let entries: [(size: Int, scale: Int, file: String)] = [
    (16,  1, "icon_16x16.png"),
    (16,  2, "icon_16x16@2x.png"),
    (32,  1, "icon_32x32.png"),
    (32,  2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let master = renderMaster(size: 1024)

for e in entries {
    let px = e.size * e.scale
    writePNG(downsample(master, to: px), to: "\(outDir)/\(e.file)")
    print("wrote \(e.file) (\(px)×\(px))")
}

let contentsJSON = """
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try! contentsJSON.write(toFile: "\(outDir)/Contents.json", atomically: true, encoding: .utf8)
