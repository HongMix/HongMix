import CoreGraphics
import Foundation
let ids = CommandLine.arguments.dropFirst().compactMap { UInt32($0) }
let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in all {
    let n = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    if ids.contains(n) || (ids.isEmpty && owner.contains("HongMix")) {
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        print(n, owner, w[kCGWindowOwnerPID as String] ?? "", "|", w[kCGWindowName as String] ?? "-", "|", b["Width"] ?? 0, "x", b["Height"] ?? 0, "onscreen:", w[kCGWindowIsOnscreen as String] ?? false, "layer:", w[kCGWindowLayer as String] ?? 0)
    }
}
