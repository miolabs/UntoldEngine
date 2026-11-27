import AppKit
let a = CommandLine.arguments
let img = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let w = img.width, h = img.height
var buf = [UInt8](repeating: 0, count: w*h*4)
let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
let x = Int(a[2])!, y0 = Int(a[3])!, y1 = Int(a[4])!, step = Int(a[5])!
var line = "x=\(x): "
var y = y0
while y <= y1 { let i = (y*w + x)*4; let l = (Int(buf[i]) + Int(buf[i+1]) + Int(buf[i+2])) / 3; line += "\(y):\(l) "; y += step }
print(line)
