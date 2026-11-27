import AppKit
// compose out.png height img1 [crop x y w h] img2 [crop ...] ...  -> side by side at the given height
var args = Array(CommandLine.arguments.dropFirst())
let outPath = args.removeFirst(); let height = Int(args.removeFirst())!
var images: [CGImage] = []
while !args.isEmpty {
    let path = args.removeFirst()
    var img = NSImage(contentsOfFile: path)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    if args.first == "crop" {
        args.removeFirst()
        let x = Int(args.removeFirst())!, y = Int(args.removeFirst())!, w = Int(args.removeFirst())!, h = Int(args.removeFirst())!
        img = img.cropping(to: CGRect(x: x, y: y, width: w, height: h))!
    }
    images.append(img)
}
let gap = 12
let widths = images.map { Int(Double($0.width) * Double(height) / Double($0.height)) }
let totalW = widths.reduce(0, +) + gap * (images.count - 1)
let ctx = CGContext(data: nil, width: totalW, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: totalW, height: height))
ctx.interpolationQuality = .high
var x = 0
for (i, img) in images.enumerated() {
    ctx.draw(img, in: CGRect(x: x, y: 0, width: widths[i], height: height))
    x += widths[i] + gap
}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) \(totalW)x\(height)")
