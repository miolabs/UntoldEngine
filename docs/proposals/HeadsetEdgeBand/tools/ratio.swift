import AppKit
// Writes (on / off) per pixel as a grayscale PNG: 1.0 -> white, 0.5 -> mid grey; reveals an AO multiply.
let a = CommandLine.arguments
func load(_ p: String) -> (Int, Int, [UInt8]) {
    let img = NSImage(contentsOfFile: p)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w*h*4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, buf)
}
let (w, h, on) = load(a[1]); let (_, _, off) = load(a[2])
var out = [UInt8](repeating: 255, count: w*h*4)
var hist = [Int](repeating: 0, count: 11)
for i in 0 ..< w*h {
    let lOn = Double(on[i*4]) + Double(on[i*4+1]) + Double(on[i*4+2])
    let lOff = Double(off[i*4]) + Double(off[i*4+1]) + Double(off[i*4+2])
    let r = lOff > 6 ? min(1.0, lOn / lOff) : 1.0
    let v = UInt8(max(0, min(255, r * 255)))
    out[i*4] = v; out[i*4+1] = v; out[i*4+2] = v; out[i*4+3] = 255
    hist[Int(r * 10)] += 1
}
let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let cg = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: cg)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[3]))
print("ratio histogram (0.0-0.1 ... 1.0):", hist)
