import SwiftUI
import AppKit
import QuartzCore

/// Stereo peak meter drawn with Core Animation layers and refreshed by one shared 30 Hz timer.
/// (A SwiftUI TimelineView per strip re-ran the view graph 20×/s per strip — the main-thread CPU hog.)
struct LayerMeter: NSViewRepresentable {
    let meter: () -> (Float, Float)

    func makeNSView(context: Context) -> LayerMeterView {
        let v = LayerMeterView()
        v.source = meter
        MeterClock.shared.add(v)
        return v
    }

    func updateNSView(_ v: LayerMeterView, context: Context) { v.source = meter }

    static func dismantleNSView(_ v: LayerMeterView, coordinator: ()) { MeterClock.shared.remove(v) }
}

final class LayerMeterView: NSView {
    var source: () -> (Float, Float) = { (0, 0) }
    private let bars = [CAGradientLayer(), CAGradientLayer()]
    private let masks = [CALayer(), CALayer()]
    private var last: (CGFloat, CGFloat) = (-1, -1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        for (b, m) in zip(bars, masks) {
            b.colors = [NSColor.systemGreen.cgColor, NSColor.systemGreen.cgColor, NSColor.systemYellow.cgColor, NSColor.systemRed.cgColor]
            b.locations = [0, 0.7, 0.85, 1]
            b.startPoint = CGPoint(x: 0.5, y: 0); b.endPoint = CGPoint(x: 0.5, y: 1)
            m.backgroundColor = NSColor.white.cgColor
            m.anchorPoint = .zero
            b.mask = m
            layer?.addSublayer(b)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let w = (bounds.width - 1) / 2
        bars[0].frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
        bars[1].frame = CGRect(x: w + 1, y: 0, width: w, height: bounds.height)
        CATransaction.commit()
        last = (-1, -1)
        refresh()
    }

    private static func frac(_ level: Float) -> CGFloat {
        let db = level > 0 ? 20 * log10(Double(level)) : -90
        return CGFloat(max(0, min(1, (db + 60) / 60)))
    }

    func refresh() {
        let m = source()
        let f = (Self.frac(m.0), Self.frac(m.1))
        // skip work when nothing moved by more than half a pixel
        let h = bounds.height
        if abs(f.0 - last.0) * h < 0.5 && abs(f.1 - last.1) * h < 0.5 { return }
        last = f
        CATransaction.begin(); CATransaction.setDisableActions(true)
        masks[0].frame = CGRect(x: 0, y: 0, width: bars[0].bounds.width, height: h * f.0)
        masks[1].frame = CGRect(x: 0, y: 0, width: bars[1].bounds.width, height: h * f.1)
        CATransaction.commit()
    }
}

/// One timer for every meter in the app (main run loop, common modes).
final class MeterClock {
    static let shared = MeterClock()
    private var views = NSHashTable<LayerMeterView>.weakObjects()
    private var timer: Timer?

    func add(_ v: LayerMeterView) {
        views.add(v)
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func remove(_ v: LayerMeterView) { views.remove(v) }

    private func tick() {
        for v in views.allObjects where v.window != nil && !v.isHiddenOrHasHiddenAncestor { v.refresh() }
    }
}
