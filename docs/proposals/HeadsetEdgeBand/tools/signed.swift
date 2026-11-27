import AppKit
// signed fixed.png reference.png out.png thr -> red where fixed is darker than reference, green where brighter
let a = CommandLine.arguments
func load(_ p: String) -> (Int, Int, [UInt8]) {
    let img = NSImage(contentsOfFile: p)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w*h*4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, buf)
}
let (w, h, x) = load(a[1]); let (_, _, y) = load(a[2]); let thr = Int(a[4])!
var out = [UInt8](repeating: 0, count: w*h*4); var darker = 0, brighter = 0
for i in 0 ..< w*h {
    let lx = Int(x[i*4]) + Int(x[i*4+1]) + Int(x[i*4+2]); let ly = Int(y[i*4]) + Int(y[i*4+1]) + Int(y[i*4+2])
    let d = lx - ly
    let base = UInt8(min(255, ly / 9))
    out[i*4] = base; out[i*4+1] = base; out[i*4+2] = base; out[i*4+3] = 255
    if d < -thr { darker += 1; out[i*4] = 255; out[i*4+1] = 0; out[i*4+2] = 0 }
    else if d > thr { brighter += 1; out[i*4] = 0; out[i*4+1] = 255; out[i*4+2] = 0 }
}
let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[3]))
print("darker in the first: \(darker), brighter in the first: \(brighter) (of \(w*h))")
