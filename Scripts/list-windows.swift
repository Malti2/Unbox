import AppKit
import CoreGraphics

// Prints every on-screen window owned by the given process name, with its center relative to the main display.
let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Unbox"
let screen = CGDisplayBounds(CGMainDisplayID())
print("SCREEN \(Int(screen.width))x\(Int(screen.height))")
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
var count = 0
for w in list where (w[kCGWindowOwnerName as String] as? String) == owner && (w[kCGWindowLayer as String] as? Int) == 0 {
    guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    count += 1
    let cx = (b["X"] ?? 0) + (b["Width"] ?? 0) / 2, cy = (b["Y"] ?? 0) + (b["Height"] ?? 0) / 2
    print("WINDOW \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0)) at \(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) center offset from screen center: \(Int(cx - screen.midX)),\(Int(cy - screen.midY))")
}
print("COUNT \(count)")
