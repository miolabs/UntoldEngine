import AppKit
let a = CommandLine.arguments
func load(_ p: String) -> (CGImage, [UInt8]) {
    let img = NSImage(contentsOfFile: p)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w*h*4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (img, buf)
}
let (i1, b1) = load(a[1]); let (_, b2) = load(a[2])
let w = i1.width, h = i1.height
var sum = 0.0; var maxd = 0; var changed = 0
for i in stride(from: 0, to: w*h*4, by: 4) {
    let d = abs(Int(b1[i]) - Int(b2[i])) + abs(Int(b1[i+1]) - Int(b2[i+1])) + abs(Int(b1[i+2]) - Int(b2[i+2]))
    sum += Double(d); if d > maxd { maxd = d }; if d > 30 { changed += 1 }
}
print(String(format: "mean abs diff per pixel (sum of 3 channels): %.3f, max %d, pixels changed by >30: %d of %d (%.2f%%)", sum/Double(w*h), maxd, changed, w*h, 100.0*Double(changed)/Double(w*h)))
