import AppKit
// mask a.png b.png out.png threshold -> white where |a-b| summed over RGB exceeds threshold; prints the count
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
var out = [UInt8](repeating: 0, count: w*h*4); var n = 0
for i in 0 ..< w*h {
    let d = abs(Int(x[i*4]) - Int(y[i*4])) + abs(Int(x[i*4+1]) - Int(y[i*4+1])) + abs(Int(x[i*4+2]) - Int(y[i*4+2]))
    let v: UInt8 = d > thr ? 255 : UInt8(min(255, x[i*4] / 3))
    out[i*4] = v; out[i*4+1] = d > thr ? 0 : v; out[i*4+2] = d > thr ? 0 : v; out[i*4+3] = 255
    if d > thr { n += 1 }
}
let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[3]))
print("pixels differing by more than \(thr): \(n) of \(w*h) (\(String(format: "%.2f", 100.0*Double(n)/Double(w*h)))%)")
