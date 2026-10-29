import Foundation
import Metal
import CoreVideo

/// 3D LUT (.cube, Adobe/Resolve format) loaded into a Metal 3D texture.
final class CubeLUT {
    let size: Int
    let texture: MTLTexture
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>
    let title: String

    init(size: Int, texture: MTLTexture, domainMin: SIMD3<Float>, domainMax: SIMD3<Float>, title: String) {
        self.size = size; self.texture = texture; self.domainMin = domainMin; self.domainMax = domainMax; self.title = title
    }

    enum LoadError: Error, CustomStringConvertible {
        case unreadable, notCube, oneD, badData(Int, Int)
        var description: String {
            switch self {
            case .unreadable: return L("파일을 읽을 수 없음")
            case .notCube: return L("LUT_3D_SIZE가 없는 파일 (.cube 3D LUT가 아님)")
            case .oneD: return L("1D LUT는 지원하지 않습니다 (3D .cube만)")
            case .badData(let got, let want): return Lf("데이터 줄 수가 맞지 않음 (%@ / %@)", "\(got)", "\(want)")
            }
        }
    }

    static func load(path: String, device: MTLDevice) throws -> CubeLUT {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw LoadError.unreadable
        }
        var size = 0
        var dmin = SIMD3<Float>(0, 0, 0), dmax = SIMD3<Float>(1, 1, 1)
        var title = (path as NSString).lastPathComponent
        var values: [Float] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let first = line.first!
            if first.isLetter {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                switch parts.first.map(String.init)?.uppercased() {
                case "LUT_3D_SIZE":
                    size = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                    values.reserveCapacity(size * size * size * 4)
                case "LUT_1D_SIZE": throw LoadError.oneD
                case "TITLE": title = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                case "DOMAIN_MIN" where parts.count >= 4:
                    dmin = SIMD3(Float(parts[1]) ?? 0, Float(parts[2]) ?? 0, Float(parts[3]) ?? 0)
                case "DOMAIN_MAX" where parts.count >= 4:
                    dmax = SIMD3(Float(parts[1]) ?? 1, Float(parts[2]) ?? 1, Float(parts[3]) ?? 1)
                default: break
                }
                continue
            }
            var n = 0
            for p in line.split(separator: " ", omittingEmptySubsequences: true) where n < 3 {
                guard let v = Float(p) else { break }
                values.append(v); n += 1
            }
            if n == 3 { values.append(1) } else if n > 0 { values.removeLast(n) }
        }
        guard size >= 2, size <= 256 else { throw LoadError.notCube }
        let want = size * size * size
        guard values.count / 4 == want else { throw LoadError.badData(values.count / 4, want) }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba32Float
        d.width = size; d.height = size; d.depth = size
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { throw LoadError.unreadable }
        values.withUnsafeBytes { raw in
            // .cube order: red changes fastest, then green, then blue → x = R, y = G, z = B
            tex.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: size * 16, bytesPerImage: size * size * 16)
        }
        return CubeLUT(size: size, texture: tex, domainMin: dmin, domainMax: dmax, title: title)
    }
}

/// Loaded LUTs by path. Loading happens off the render thread; the render thread only looks up.
final class LUTCache {
    static let shared = LUTCache()
    private let lock = NSLock()
    private var luts: [String: CubeLUT] = [:]
    private var errors: [String: String] = [:]
    private var loading: Set<String> = []
    private let queue = DispatchQueue(label: "lut.load", qos: .userInitiated, attributes: .concurrent)

    /// Render thread: the LUT if it is loaded (starts loading otherwise).
    func lut(_ path: String) -> CubeLUT? {
        lock.lock()
        let l = luts[path]
        let need = l == nil && errors[path] == nil && !loading.contains(path)
        lock.unlock()
        if need { preload(path) }
        return l
    }

    func isLoaded(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return luts[path] != nil
    }

    func error(_ path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return errors[path]
    }

    func preload(_ path: String, done: ((String?) -> Void)? = nil) {
        guard !path.isEmpty else { done?(nil); return }
        lock.lock()
        if luts[path] != nil { lock.unlock(); done?(nil); return }
        loading.insert(path)
        errors[path] = nil
        lock.unlock()
        queue.async {
            var err: String?
            do {
                let l = try CubeLUT.load(path: path, device: MetalContext.shared.device)
                self.lock.lock(); self.luts[path] = l; self.lock.unlock()
            } catch {
                err = "\(error)"
                self.lock.lock(); self.errors[path] = err; self.lock.unlock()
            }
            self.lock.lock(); self.loading.remove(path); self.lock.unlock()
            if let done = done { DispatchQueue.main.async { done(err) } }
        }
    }

    func reload(_ path: String, done: ((String?) -> Void)? = nil) {
        lock.lock(); luts[path] = nil; errors[path] = nil; lock.unlock()
        preload(path, done: done)
    }
}

/// Must match `LutParams` in Mixer.metal.
struct LutParams {
    var strength: Float = 1
    var size: Float = 33
    var premul: Int32 = 0
    var pad: Int32 = 0
    var dminR: Float = 0, dminG: Float = 0, dminB: Float = 0
    var dmaxR: Float = 1, dmaxG: Float = 1, dmaxB: Float = 1
}
