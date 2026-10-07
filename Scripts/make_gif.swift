// swift Scripts/make_gif.swift <frames-dir> <out.gif> <fps>
// Joins numbered PNG frames into a looping GIF with ImageIO, so the README art needs
// nothing beyond the macOS toolchain.
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 4, let fps = Double(args[3]) else {
    fputs("usage: make_gif.swift <frames-dir> <out.gif> <fps>\n", stderr); exit(2)
}
let dir = URL(fileURLWithPath: args[1])
let frames = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "png" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
guard !frames.isEmpty,
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
else { fputs("no frames, or cannot write \(args[2])\n", stderr); exit(1) }

CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps,
                                                  kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
for url in frames {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
    CGImageDestinationAddImage(dest, image, frameProps)
}
guard CGImageDestinationFinalize(dest) else { fputs("GIF encode failed\n", stderr); exit(1) }
print("\(frames.count) frames -> \(args[2])")
