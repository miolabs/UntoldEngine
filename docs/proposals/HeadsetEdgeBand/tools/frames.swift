import AVFoundation
import AppKit

let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[1])
let outDir = args[2]
let step = Double(args[3]) ?? 1.0
let asset = AVURLAsset(url: url)
let sem = DispatchSemaphore(value: 0)
var duration = CMTime.zero
var size = CGSize.zero
var fps: Float = 0
Task {
    duration = try await asset.load(.duration)
    if let track = try await asset.loadTracks(withMediaType: .video).first {
        size = try await track.load(.naturalSize)
        fps = try await track.load(.nominalFrameRate)
    }
    sem.signal()
}
sem.wait()
print("duration \(duration.seconds) s, size \(size), fps \(fps)")
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
var t = 0.0
var i = 0
while t < duration.seconds {
    let time = CMTime(seconds: t, preferredTimescale: 600)
    do {
        let cg = try gen.copyCGImage(at: time, actualTime: nil)
        let rep = NSBitmapImageRep(cgImage: cg)
        let data = rep.representation(using: .png, properties: [:])!
        let name = String(format: "%@/f%04d_%06.2fs.png", outDir, i, t)
        try data.write(to: URL(fileURLWithPath: name))
    } catch {
        print("frame at \(t) failed: \(error)")
    }
    t += step
    i += 1
}
print("wrote \(i) frames")
