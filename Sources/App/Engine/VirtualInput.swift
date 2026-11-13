import Foundation
import CoreVideo

/// vMix "Virtual Input": a second input showing the same picture as another input — no second file
/// open, no second decoder. Every frame the original stores is handed to this input's slot as the very
/// same CVPixelBuffer (`VideoSlot.addMirror`), so it costs no decoding or copying.
///
/// It has its own position, crop, colour, key, layers and name, so one camera / clip can appear twice
/// with different framing (e.g. full shot in Program and a cropped close-up as a layer).
/// Playback and sound belong to the original: going on air with a virtual input plays the original's
/// media like a layer does (SwitcherEngine.layerSources), and the virtual input has no audio of its own.
final class VirtualInput: InputSource {
    private(set) weak var source: InputSource?
    /// The original's id — fixed at creation, safe to read from the render thread.
    let originalID: UUID?
    var sourceID: UUID? { originalID }

    override init(config: InputConfig) {
        originalID = UUID(uuidString: config.virtualOf)
        super.init(config: config)
    }

    override var alphaPremultiplied: Bool { source?.alphaPremultiplied ?? false }

    /// Called by the engine whenever the original may have changed (added, replaced, removed).
    func link(_ s: InputSource?) {
        guard s !== source else { return }
        if let old = source { old.video.removeMirror(video) }
        source = s
        if let s {
            s.video.addMirror(video)
            postStatus(Int32(MC_STATE_RUNNING), Lf("가상 입력 · 원본: %@", s.name))
        } else {
            video.clear()
            postStatus(Int32(MC_STATE_ERROR), L("가상 입력 · 원본 입력이 없습니다"))
        }
    }

    override func stop() { link(nil) }
}
