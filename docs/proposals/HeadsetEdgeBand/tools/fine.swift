import AVFoundation
import AppKit
let a = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let out = a[2]; let from = Double(a[3])!; let to = Double(a[4])!; let step = Double(a[5])!
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
var t = from; var i = 0
while t <= to {
    let cg = try! gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 6000), actualTime: nil)
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: String(format: "%@/g%03d_%06.3fs.png", out, i, t)))
    t += step; i += 1
}
print("wrote \(i)")
