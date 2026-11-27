import AppKit
// rimstat fixed.png reference.png thr -> how dark the pixels that got darker are, relative to the reference
let a = CommandLine.arguments
func load(_ p: String) -> (Int, Int, [UInt8]) {
    let img = NSImage(contentsOfFile: p)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w*h*4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, buf)
}
let (w, h, x) = load(a[1]); let (_, _, y) = load(a[2]); let thr = Int(a[3])!
var n = 0; var sumRatio = 0.0; var minRatio = 1.0; var below50 = 0
for i in 0 ..< w*h {
    let lx = Double(Int(x[i*4]) + Int(x[i*4+1]) + Int(x[i*4+2])); let ly = Double(Int(y[i*4]) + Int(y[i*4+1]) + Int(y[i*4+2]))
    if ly - lx > Double(thr) { n += 1; let r = lx / max(ly, 1); sumRatio += r; minRatio = min(minRatio, r); if r < 0.5 { below50 += 1 } }
}
print(String(format: "darker pixels: %d (%.2f%% of the frame); their brightness vs the reference: mean %.2f, min %.2f; below half: %d", n, 100.0*Double(n)/Double(w*h), n > 0 ? sumRatio/Double(n) : 1, minRatio, below50))
