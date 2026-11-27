// Stand-in for Tests/UntoldEngineRenderTests/Resources/compare_psnr.py on a machine
// without OpenCV and scikit-image: the same arguments, output lines, arithmetic
// (OpenCV's fixed-point grey conversion, skimage's PSNR over the type's range) and exit
// codes. Invoked as the tests invoke python: `psnr compare_psnr.py <ref> <test> [flags]`.
// PSNR_LOG=<file> appends "<value> <ref> <test>" per comparison.
import Foundation
import ImageIO
import CoreGraphics

struct Picture {
    var width: Int
    var height: Int
    var bits: Int           // 8 or 16 per component
    var channels: Int       // 1 (grey) or 3 (RGB), alpha dropped
    var samples: [Double]   // row-major, channels interleaved, integer values
}

func load(_ path: String) -> Picture? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
          let data = image.dataProvider?.data else { return nil }
    let bytes = CFDataGetBytePtr(data)!
    let bits = image.bitsPerComponent
    let bytesPerPixel = image.bitsPerPixel / 8
    let perPixel = image.bitsPerPixel / bits
    let alpha = image.alphaInfo
    let alphaFirst = alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst
    let hasAlphaSlot = alpha != .none
    let colour = hasAlphaSlot ? perPixel - 1 : perPixel
    let littleEndian = image.bitmapInfo.contains(.byteOrder16Little) || (bits == 8)
    let channels = colour >= 3 ? 3 : 1
    var samples = [Double](repeating: 0, count: image.width * image.height * channels)
    var out = 0
    for y in 0 ..< image.height {
        let row = bytes + y * image.bytesPerRow
        for x in 0 ..< image.width {
            let pixel = row + x * bytesPerPixel
            for c in 0 ..< channels {
                let index = (alphaFirst ? 1 : 0) + c
                let value: Double
                if bits == 16 {
                    let b0 = Double(pixel[index * 2]), b1 = Double(pixel[index * 2 + 1])
                    value = littleEndian ? b0 + b1 * 256 : b0 * 256 + b1
                } else {
                    value = Double(pixel[index])
                }
                samples[out] = value
                out += 1
            }
        }
    }
    return Picture(width: image.width, height: image.height, bits: bits, channels: channels, samples: samples)
}

/// OpenCV's RGB2GRAY in fixed point: (R·4899 + G·9617 + B·1868 + 2^13) >> 14.
func grey(_ p: Picture) -> [Double] {
    if p.channels == 1 { return p.samples }
    var g = [Double](repeating: 0, count: p.width * p.height)
    for i in 0 ..< g.count {
        let r = Int(p.samples[i * 3]), gg = Int(p.samples[i * 3 + 1]), b = Int(p.samples[i * 3 + 2])
        g[i] = Double((r * 4899 + gg * 9617 + b * 1868 + (1 << 13)) >> 14)
    }
    return g
}

/// Box resize (INTER_AREA for a reduction) of a 3- or 1-channel picture to the reference size.
func resized(_ p: Picture, to width: Int, height: Int) -> Picture {
    var q = Picture(width: width, height: height, bits: p.bits, channels: p.channels, samples: [])
    q.samples = [Double](repeating: 0, count: width * height * p.channels)
    for y in 0 ..< height {
        let y0 = y * p.height / height, y1 = max(y0 + 1, (y + 1) * p.height / height)
        for x in 0 ..< width {
            let x0 = x * p.width / width, x1 = max(x0 + 1, (x + 1) * p.width / width)
            for c in 0 ..< p.channels {
                var sum = 0.0; var n = 0.0
                for yy in y0 ..< y1 { for xx in x0 ..< x1 { sum += p.samples[(yy * p.width + xx) * p.channels + c]; n += 1 } }
                q.samples[(y * width + x) * p.channels + c] = (sum / n).rounded()
            }
        }
    }
    return q
}

var args = CommandLine.arguments
// Drop the script path the tests pass first.
if args.count > 1, args[1].hasSuffix(".py") { args.remove(at: 1) }
if args.count < 3 {
    FileHandle.standardError.write("Usage: compare_psnr.py <reference.png> <test.png> [--threshold 30] [--resize yes|no] [--mode gray|rgb]\n".data(using: .utf8)!)
    exit(2)
}
let refPath = args[1], testPath = args[2]
var threshold = 30.0, resize = "yes", mode = "gray"
var i = 3
while i < args.count {
    if args[i] == "--threshold", i + 1 < args.count { threshold = Double(args[i + 1]) ?? 30; i += 2 }
    else if args[i] == "--resize", i + 1 < args.count { resize = args[i + 1].lowercased(); i += 2 }
    else if args[i] == "--mode", i + 1 < args.count { mode = args[i + 1].lowercased(); i += 2 }
    else { FileHandle.standardError.write("Unknown/invalid arg: \(args[i])\n".data(using: .utf8)!); exit(2) }
}
print("[compare_psnr] ref: \(refPath)")
print("[compare_psnr] test: \(testPath)")
print("[compare_psnr] threshold=\(threshold)dB, resize=\(resize), mode=\(mode)")
for path in [refPath, testPath] where !FileManager.default.fileExists(atPath: path) {
    FileHandle.standardError.write("[compare_psnr] ERROR: not found: \(path)\n".data(using: .utf8)!); exit(3)
}
guard let ref = load(refPath) else { FileHandle.standardError.write("[compare_psnr] ERROR: failed to read reference\n".data(using: .utf8)!); exit(4) }
guard var test = load(testPath) else { FileHandle.standardError.write("[compare_psnr] ERROR: failed to read test\n".data(using: .utf8)!); exit(4) }
if ref.width != test.width || ref.height != test.height {
    print("[compare_psnr] size mismatch: ref(\(ref.height), \(ref.width)) vs test(\(test.height), \(test.width))")
    if resize == "yes" {
        test = resized(test, to: ref.width, height: ref.height)
        print("[compare_psnr] resized test -> (\(test.height), \(test.width))")
    } else {
        FileHandle.standardError.write("[compare_psnr] ERROR: dimensions differ and --resize=no\n".data(using: .utf8)!); exit(5)
    }
}
var a: [Double], b: [Double]
if mode == "gray" {
    a = grey(ref); b = grey(test)
} else {
    func rgb(_ p: Picture) -> [Double] {
        if p.channels == 3 { return p.samples }
        var out = [Double](repeating: 0, count: p.samples.count * 3)
        for i in 0 ..< p.samples.count { out[i * 3] = p.samples[i]; out[i * 3 + 1] = p.samples[i]; out[i * 3 + 2] = p.samples[i] }
        return out
    }
    a = rgb(ref); b = rgb(test)
}
if a.count != b.count {
    // One picture grey, the other colour: OpenCV would have given both the same shape; mirror by greying both.
    a = grey(ref); b = grey(test)
}
let dataRange = Double((1 << max(ref.bits, test.bits)) - 1)
var mse = 0.0
for i in 0 ..< a.count { let d = a[i] - b[i]; mse += d * d }
mse /= Double(a.count)
let psnr = mse == 0 ? Double.infinity : 10 * log10(dataRange * dataRange / mse)
print(psnr.isInfinite ? "inf" : String(format: "%.6f", psnr))
if let log = ProcessInfo.processInfo.environment["PSNR_LOG"], let handle = FileHandle(forWritingAtPath: log) ?? (FileManager.default.createFile(atPath: log, contents: nil) ? FileHandle(forWritingAtPath: log) : nil) {
    handle.seekToEndOfFile()
    handle.write("\(psnr.isInfinite ? "inf" : String(format: "%.6f", psnr)) \(refPath) \(testPath)\n".data(using: .utf8)!)
    handle.closeFile()
}
exit(psnr < threshold ? 1 : 0)
