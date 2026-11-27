import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    let onScreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    let name = w[kCGWindowName as String] as? String ?? "?"
    print("window layer=\(layer) onscreen=\(onScreen) bounds=\(b["Width"] ?? 0)x\(b["Height"] ?? 0) at (\(b["X"] ?? 0),\(b["Y"] ?? 0)) name=\(name)")
}
