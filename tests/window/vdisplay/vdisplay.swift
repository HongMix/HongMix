// Usage: vdisplay <seconds> — adds a 1920×1080 virtual display, prints its ID, removes it on exit/SIGTERM.
import Foundation
import CoreGraphics
let secs = Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60
let d = CGVirtualDisplayDescriptor()
d.queue = DispatchQueue.main
d.name = "HongMix Test Display"
d.maxPixelsWide = 1920; d.maxPixelsHigh = 1080
d.sizeInMillimeters = CGSize(width: 530, height: 300)
d.productID = 0x1234; d.vendorID = 0x3456; d.serialNum = 0x0001
guard var v: CGVirtualDisplay? = CGVirtualDisplay(descriptor: d) else { print("CGVirtualDisplay unavailable"); exit(1) }
let s = CGVirtualDisplaySettings()
s.hiDPI = 0
s.modes = [CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60)]
guard v!.apply(s) else { print("applySettings failed"); exit(1) }
print("display \(v!.displayID)"); fflush(stdout)
signal(SIGTERM, SIG_IGN)
let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
// Release the display object and let WindowServer process the removal before exiting.
func finish() { v = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) } }
src.setEventHandler { finish() }
src.resume()
DispatchQueue.main.asyncAfter(deadline: .now() + secs) { finish() }
dispatchMain()
