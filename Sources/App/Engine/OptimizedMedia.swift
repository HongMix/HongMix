import Foundation
import AVFoundation

/// "최적화된 미디어" (like Final Cut Pro): files the Media Engine can't decode in hardware
/// (e.g. H.264 High 4:2:2 10-bit) are copied to Apple ProRes 422, which Apple Silicon decodes in
/// hardware. The copy is written next to the original and the input switches to it.
enum OptimizedMedia {
    static func outputURL(for source: URL) -> URL {
        source.deletingLastPathComponent()
            .appendingPathComponent(source.deletingPathExtension().lastPathComponent + "_HongMix_ProRes.mov")
    }

    /// Converts in the background and calls `done` on the main queue with the new path or an error text.
    static func makeProRes(from path: String,
                           progress: @escaping (Double) -> Void,
                           done: @escaping (Result<String, Error>) -> Void) {
        let src = URL(fileURLWithPath: path)
        let dst = outputURL(for: src)
        if FileManager.default.fileExists(atPath: dst.path) {
            DispatchQueue.main.async { done(.success(dst.path)) }
            return
        }
        let asset = AVURLAsset(url: src)
        let preset = AVAssetExportPresetAppleProRes422LPCM
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            DispatchQueue.main.async { done(.failure(OptimizedMediaError.unsupported)) }
            return
        }
        let tmp = dst.deletingLastPathComponent().appendingPathComponent("." + dst.lastPathComponent + ".part.mov")
        try? FileManager.default.removeItem(at: tmp)
        export.outputURL = tmp
        export.outputFileType = .mov
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 0.5)
        timer.setEventHandler { progress(Double(export.progress)) }
        timer.resume()
        export.exportAsynchronously {
            DispatchQueue.main.async {
                timer.cancel()
                if export.status == .completed {
                    do {
                        try FileManager.default.moveItem(at: tmp, to: dst)
                        done(.success(dst.path))
                    } catch { done(.failure(error)) }
                } else {
                    try? FileManager.default.removeItem(at: tmp)
                    done(.failure(export.error ?? OptimizedMediaError.unsupported))
                }
            }
        }
    }
}

enum OptimizedMediaError: LocalizedError {
    case unsupported
    var errorDescription: String? { L("이 파일은 ProRes로 변환할 수 없습니다") }
}

extension FFmpegInput {
    /// True when the file is being decoded on the CPU (hardware decoder refused the format).
    var isSoftwareDecoded: Bool { videoDecodeModeName() == "Software" }

    /// Swap this input to a different file (keeps position at 0, keeps play state).
    func replaceFile(with path: String) {
        let wasPlaying = playing
        if isList, playlist.indices.contains(playlistIndex) {
            playlist[playlistIndex] = path
            selectItem(playlistIndex, play: wasPlaying)
            return
        }
        config.url = path
        stop()
        audio.clear()
        start()
        if wasPlaying && !playing { playing = true }
    }
}
