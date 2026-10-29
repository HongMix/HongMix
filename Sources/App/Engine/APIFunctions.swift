import AppKit
import Foundation
import CoreImage

/// Executes "Function" calls (HTTP /api/?Function=… and TCP "FUNCTION …") and builds the XML state.
/// Function names and parameters follow the public vMix Web/TCP API reference so existing control
/// surfaces keep working. Main thread only.
enum APIProcessor {

    /// Function families that exist in the reference but are intentionally not implemented.
    static let unsupportedPrefixes = ["replay", "ptz", "script", "playlist",
                                      "nextplaylist", "previousplaylist", "selectplaylist", "startplaylist",
                                      "stopplaylist", "videocall", "list", "layer", "multiviewoverlay",
                                      "movemultiviewoverlay", "setmultiviewoverlay", "audioplugin", "busaaudioplugin",
                                      "busbaudioplugin", "busxaudioplugin", "masteraudioplugin", "ndicommand",
                                      "ndistartrecording", "ndistoprecording", "previewoverlayinput",
                                      "setdynamicinput", "selectcategory", "selectindex", "nextitem", "previousitem",
                                      "nextpicture", "previouspicture", "setpictureeffect", "setpicturetransition",
                                      "videodelay", "savevideodelay", "createvirtualinput", "autoplayfirst",
                                      "autoplaynext", "audiochannelmatrix", "setvolumechannelmixer",
                                      "colourcorrectionauto", "inputpreview", "waitforcompletion", "livepause",
                                      "liveplaypause", "keypress", "lastpreset", "openpreset", "savepreset",
                                      "writedurationtorecordinglog"]

    static func resolveInput(_ value: String?, _ e: SwitcherEngine) -> InputSource? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if let n = Int(v), n >= 1, n <= e.inputs.count { return e.inputs[n - 1] }
        if let id = UUID(uuidString: v) { return e.input(withID: id) }
        return e.inputs.first { $0.name.caseInsensitiveCompare(v) == .orderedSame }
    }

    /// Parses "Input=1&Value=50" (URL-escaped) into lowercase keys.
    static func parseQuery(_ q: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let k = kv.first?.removingPercentEncoding?.lowercased() else { continue }
            let v = kv.count > 1 ? (kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]) : ""
            out[k] = v
        }
        return out
    }

    private static func float(_ s: String) -> Float? { Float(s.trimmingCharacters(in: .whitespaces)) }

    /// "A", "BusA", "a" -> bus index 1…7; "M"/"Master" -> 0
    private static func busIndex(_ v: String) -> Int? {
        var s = v.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("BUS") { s.removeFirst(3) }
        if s == "MASTER" { return 0 }
        return AudioBus.index(s)
    }

    /// Output source names used by SetOutput2…4: Output, Preview, MultiView, Clean, Input (+Input=)
    private static func busSource(_ v: String, input: InputSource?) -> BusSource? {
        switch v.lowercased() {
        case "output", "program": return .program
        case "preview": return .preview
        case "multiview": return .multiview
        case "clean", "cleanfeed", "output (clean)": return .clean
        case "input": return input.map { .input($0.id) }
        default:
            return input.map { .input($0.id) }
        }
    }

    /// "Output" -> 1, "Output2" -> 2 …
    private static func busNumber(_ v: String) -> Int? {
        let s = v.lowercased().replacingOccurrences(of: " ", with: "")
        if s == "output" || s == "output1" { return 1 }
        if s.hasPrefix("output"), let n = Int(s.dropFirst(6)), (1...4).contains(n) { return n }
        if let n = Int(s), (1...4).contains(n) { return n }
        return nil
    }

    /// Returns nil on success, or an error message.
    static func perform(_ function: String, _ q: [String: String], _ e: SwitcherEngine) -> String? {
        let fn = function.lowercased()
        let input = resolveInput(q["input"], e)
        let value = q["value"] ?? ""
        let durationMs = Int(q["duration"] ?? "")
        let title = input as? TitleInput
        func needInput() -> String { "Input not found" }

        // --- Transitions by effect name: Fade, Merge, Wipe, Slide, Fly, CrossZoom, Zoom
        if let t = TransitionType.named(function), t != .dip {
            if let i = input { e.setPreview(i.id) }
            e.autoTransition(t, durationMs: durationMs ?? e.defaultTransition.durationMs)
            return nil
        }
        if let n = numberSuffix(fn, "transition") {
            if let i = input { e.setPreview(i.id) }
            e.transition(slot: n)
            return nil
        }
        if let n = numberSuffix(fn, "stinger") {
            if let i = input { e.setPreview(i.id) }
            e.stinger(n)
            return nil
        }
        if let n = numberSuffix(fn, "settransitionduration") {
            guard let ms = Int(value) else { return "Value required" }
            e.transitionSlots[n - 1].durationMs = max(0, ms)
            return nil
        }
        if let n = numberSuffix(fn, "settransitioneffect") {
            guard let t = TransitionType.named(value) else { return "Unknown effect" }
            e.transitionSlots[n - 1].type = t
            return nil
        }
        // --- Overlays: OverlayInputN, …In, …Out, …Off, …Last, …Zoom
        if fn.hasPrefix("overlayinput"), fn != "overlayinputalloff" {
            let rest = fn.dropFirst("overlayinput".count)
            guard let ch = rest.first.flatMap({ Int(String($0)) }), (1...4).contains(ch) else { return "Bad overlay" }
            switch rest.dropFirst() {
            case "", "zoom":
                guard let i = input else { return needInput() }
                e.toggleOverlay(ch, i.id)
            case "in":
                guard let i = input else { return needInput() }
                e.overlayIn(ch, i.id)
            case "out":
                e.overlayOut(ch)
            case "off":
                e.overlayOffImmediate(ch)
            case "last":
                if let id = e.overlayIDs[ch - 1] { e.overlayIn(ch, id) }
            default:
                return "Unknown overlay function"
            }
            return nil
        }
        // --- Output 2-4 sources
        if let n = numberSuffix(fn, "setoutput"), n >= 2 {
            guard let src = busSource(value, input: input) else { return "Unknown source" }
            e.setBusSource(n, src)
            return nil
        }
        // --- Audio buses by letter: BusAAudio, SetBusAVolume …
        if let r = busFunction(fn) {
            return performBus(r.bus, r.action, value, e)
        }

        switch fn {
        // ===== Transition / switching
        case "cut":
            if let i = input { e.setPreview(i.id) }
            e.cut()
        case "quickplay":
            guard let i = input else { return needInput() }
            e.quickPlay(i.id)
        case "cutdirect", "activeinput":
            guard let i = input else { return needInput() }
            e.cutDirect(i.id)
        case "previewinput":
            guard let i = input else { return needInput() }
            e.setPreview(i.id)
        case "previewinputnext", "previewinputprevious":
            guard !e.inputs.isEmpty else { return "No inputs" }
            let cur = e.number(ofID: e.previewID)
            var n = fn == "previewinputnext" ? cur + 1 : cur - 1
            if n < 1 { n = e.inputs.count }
            if n > e.inputs.count { n = 1 }
            e.setPreview(e.inputs[n - 1].id)
        case "fadetoblack", "ftb":
            e.toggleFTB()
        case "overlayinputalloff":
            e.overlayAllOff()
        case "setfader":
            e.setTBar((Double(value) ?? 0) / 255.0)

        // ===== Media transport / input properties
        case "play":
            input?.playing = true
        case "pause":
            input?.playing = false
        case "playpause":
            if let i = input { i.playing.toggle() }
        case "restart":
            input?.restart()
        case "loop":
            if let i = input { i.looping.toggle() }
        case "loopon":
            input?.looping = true
        case "loopoff":
            input?.looping = false
        case "setposition":
            guard let i = input, let ms = Double(value) else { return "Input/Value required" }
            i.seek(seconds: ms / 1000)
        case "setrate", "setrateslowmotion":
            guard let i = input, let r = Double(value) else { return "Input/Value required" }
            i.rate = max(0.05, min(4, r))
        case "markin":
            guard let i = input else { return needInput() }
            i.markIn = i.position
        case "markout":
            guard let i = input else { return needInput() }
            i.markOut = i.position
        case "markreset":
            input?.markIn = -1
            input?.markOut = -1
        case "markresetin":
            input?.markIn = -1
        case "markresetout":
            input?.markOut = -1
        case "autoplayon": input?.autoPlay = true
        case "autoplayoff": input?.autoPlay = false
        case "autopauseon": input?.autoPause = true
        case "autopauseoff": input?.autoPause = false
        case "autorestarton": input?.autoRestart = true
        case "autorestartoff": input?.autoRestart = false
        case "setinputname":
            guard let i = input, !value.isEmpty else { return "Input/Value required" }
            i.name = value
        case "removeinput":
            guard let i = input else { return needInput() }
            e.removeInput(i)
        case "moveinput":
            guard let i = input, let to = Int(value) else { return "Input/Value required" }
            e.moveInput(from: e.number(of: i) - 1, to: max(0, min(e.inputs.count - 1, to - 1)))
        case "addinput":
            return addInput(value, e)
        case "resetinput":
            input?.adjust = VideoAdjust()
        case "mirroron": input?.adjust.mirror = true
        case "mirroroff": input?.adjust.mirror = false
        case "deinterlaceon": input?.adjust.deinterlace = true
        case "deinterlaceoff": input?.adjust.deinterlace = false
        case "sharpenon": input?.adjust.sharpen = true
        case "sharpenoff": input?.adjust.sharpen = false
        case "setalpha":
            guard let i = input, let v = float(value) else { return "Input/Value required" }
            i.adjust.alpha = max(0, min(1, v / 255))
        case "setzoom":
            guard let i = input, let v = float(value) else { return "Input/Value required" }
            i.adjust.zoom = max(0.01, min(5, v))
        case "setpanx":
            guard let i = input, let v = float(value) else { return "Input/Value required" }
            i.adjust.panX = max(-2, min(2, v))
        case "setpany":
            guard let i = input, let v = float(value) else { return "Input/Value required" }
            i.adjust.panY = max(-2, min(2, v))
        case "setcropx1", "setcropx2", "setcropy1", "setcropy2":
            guard let i = input, let v = float(value) else { return "Input/Value required" }
            let c = max(0, min(1, v))
            switch fn {
            case "setcropx1": i.adjust.cropL = c
            case "setcropx2": i.adjust.cropR = 1 - c
            case "setcropy1": i.adjust.cropT = c
            default: i.adjust.cropB = 1 - c
            }
        case "setcrop":
            guard let i = input else { return needInput() }
            let v = value.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
            guard v.count == 4 else { return "Value=X1,Y1,X2,Y2" }
            i.adjust.cropL = v[0]; i.adjust.cropT = v[1]; i.adjust.cropR = 1 - v[2]; i.adjust.cropB = 1 - v[3]
        case "colourcorrectionreset":
            input?.adjust.resetColor()
        case "setccgainr", "setccgaing", "setccgainb", "setccgainrgb",
             "setccgammar", "setccgammag", "setccgammab", "setccgammargb",
             "setccliftr", "setccliftg", "setccliftb", "setccliftrgb":
            guard let i = input, let v = float(value) else { return "Input/Value required" }
            applyCC(fn, v, i)
        case "setcchue":
            guard let i = input, let v = float(value) else { return "Input/Value required" }
            i.adjust.hue = max(-180, min(180, v))
        case "setccsaturation":
            guard let i = input, let v = float(value) else { return "Input/Value required" }
            i.adjust.saturation = max(0, min(3, v))
        case "ndiselectsourcebyname":
            guard let i = input, i.kind == .ndi, !value.isEmpty else { return "NDI input/Value required" }
            var c = i.currentConfig()
            c.ndiSource = value
            e.replaceInput(i, with: c)
        case "ndiselectsourcebyindex":
            guard let i = input, i.kind == .ndi, let idx = Int(value) else { return "NDI input/Value required" }
            var buf = [CChar](repeating: 0, count: 16384)
            _ = mc_ndi_list_sources(&buf, Int32(buf.count), 0)
            let list = String(cString: buf).split(separator: "\n").map(String.init)
            guard list.indices.contains(idx) else { return "Index out of range" }
            var c = i.currentConfig()
            c.ndiSource = list[idx]
            e.replaceInput(i, with: c)

        // ===== Web Browser input
        case "browsernavigate":
            guard let b = input as? BrowserInput, !value.isEmpty else { return "Browser input/Value required" }
            b.navigate(value)
        case "browserreload":
            guard let b = input as? BrowserInput else { return "Browser input required" }
            b.reload()
        case "browserback":
            guard let b = input as? BrowserInput else { return "Browser input required" }
            b.goBack()
        case "browserforward":
            guard let b = input as? BrowserInput else { return "Browser input required" }
            b.goForward()
        case "browserkeyboardenabled", "browserkeyboarddisabled", "browsermouseenabled", "browsermousedisabled":
            guard let b = input as? BrowserInput else { return "Browser input required" }
            switch fn {
            case "browserkeyboardenabled": b.keyboardEnabled = true
            case "browserkeyboarddisabled": b.keyboardEnabled = false; b.releaseKeyboard()
            case "browsermouseenabled": b.mouseEnabled = true
            default: b.mouseEnabled = false
            }
        case "browserclick":   // BraceletMix extension: Value="x,y" normalised 0…1 — same path as a click in Preview
            guard let b = input as? BrowserInput else { return "Browser input required" }
            let p = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard p.count == 2 else { return "Value=x,y (0-1)" }
            b.forwardMouse(.leftMouseDown, at: CGPoint(x: p[0], y: p[1]))
            b.forwardMouse(.leftMouseUp, at: CGPoint(x: p[0], y: p[1]))
        case "browserevaljs":  // BraceletMix extension (diagnostics): runs JS, result goes to the status line
            guard let b = input as? BrowserInput else { return "Browser input required" }
            b.evalJS(value) { r in e.lastMessage = "JS: " + r }
            // interaction happens in the browser window opened from the input menu

        // ===== Title (GT)
        case "settext", "settextcolour", "settextcolor", "settextvisible", "settextvisibleon", "settextvisibleoff",
             "setimage", "setimagevisible", "setimagevisibleon", "setimagevisibleoff", "setcolor", "setcolour":
            guard let t = title else { return "Title input required" }
            return titleField(fn, t, q, value)
        case "setcountdown":
            guard let t = title, let s = TitleInput.parseTime(value) else { return "Title input/Value required" }
            t.setCountdown(s)
        case "startcountdown": title?.startCountdown()
        case "stopcountdown": title?.stopCountdown()
        case "pausecountdown": title?.pauseCountdown()
        case "suspendcountdown": title?.suspendCountdown()
        case "adjustcountdown":
            guard let t = title, let s = Double(value) else { return "Title input/Value required" }
            t.adjustCountdown(by: s)
        case "changecountdown":
            guard let t = title, let s = TitleInput.parseTime(value) else { return "Title input/Value required" }
            t.changeCountdown(to: s)
        case "settickerspeed":
            guard let t = title, let v = Double(value) else { return "Title input/Value required" }
            t.document.tickerSpeed = max(0, v / 100)
        case "pauserender": title?.renderPaused = true
        case "resumerender": title?.renderPaused = false
        case "selecttitlepreset":
            guard let t = title, let idx = Int(value) else { return "Title input/Value required" }
            t.applyPreset(idx)
        case "nexttitlepreset":
            guard let t = title, !t.document.presets.isEmpty else { return "No presets" }
            t.applyPreset((t.document.selectedPreset + 1) % t.document.presets.count)
        case "previoustitlepreset":
            guard let t = title, !t.document.presets.isEmpty else { return "No presets" }
            let n = t.document.presets.count
            t.applyPreset((t.document.selectedPreset - 1 + n) % n)
        case "titlebeginanimation":
            guard let t = title else { return "Title input required" }
            t.beginAnimation(out: value.lowercased().contains("out"))

        // ===== Audio (inputs)
        case "setvolume":
            guard let i = input, let v = float(value) else { return "Input/Value required" }
            i.volume = max(0, min(1, v / 100))
        case "setvolumefade":
            guard let i = input else { return needInput() }
            let p = value.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
            guard p.count == 2 else { return "Value=Volume,Milliseconds" }
            e.fadeVolume(i, to: p[0] / 100, ms: Int(p[1]))
        case "setvolumechannel1", "setvolumechannel2":
            guard let i = input, let v = float(value) else { return "Input/Value required" }
            if fn.hasSuffix("1") { i.channel1 = max(0, min(1, v / 100)) } else { i.channel2 = max(0, min(1, v / 100)) }
        case "setbalance":
            guard let i = input, let v = float(value) else { return "Input/Value required" }
            i.balance = max(-1, min(1, v))
        case "setgain":
            guard let i = input, let v = float(value) else { return "Input/Value required" }
            i.gainDB = max(0, min(24, v))
        case "setgainchannel1", "setgainchannel2":
            guard let i = input, let v = float(value) else { return "Input/Value required" }
            let lin = powf(10, max(0, min(24, v)) / 20)
            if fn.hasSuffix("1") { i.channel1 = min(lin, 16) } else { i.channel2 = min(lin, 16) }
        case "audio":
            if let i = input { i.muted.toggle() }
        case "audioon":
            input?.muted = false
        case "audiooff":
            input?.muted = true
        case "audioauto":
            if let i = input { i.audioFollowsVideo.toggle() }
        case "audioautoon":
            input?.audioFollowsVideo = true
        case "audioautooff":
            input?.audioFollowsVideo = false
        case "audiobus", "audiobuson", "audiobusoff":
            guard let i = input else { return needInput() }
            let letters = value.isEmpty ? ["M"] : value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            for l in letters {
                guard let b = busIndex(l) else { return "Unknown bus \(l)" }
                let name = AudioBus.all[b]
                switch fn {
                case "audiobuson": i.setBus(name, true)
                case "audiobusoff": i.setBus(name, false)
                default: i.setBus(name, !i.onBus(name))
                }
            }
        case "solo":
            if let i = input { i.solo.toggle() }
        case "soloon": input?.solo = true
        case "solooff": input?.solo = false
        case "setmastervolume":
            guard let v = float(value) else { return "Value required" }
            e.masterVolume = max(0, min(1, v / 100))
        case "setheadphonesvolume":
            guard let v = float(value) else { return "Value required" }
            e.headphonesVolume = max(0, min(1, v / 100))
        case "masteraudio":
            e.masterMuted.toggle()
        case "masteraudioon":
            e.masterMuted = false
        case "masteraudiooff":
            e.masterMuted = true
        case "audiomixershowhide":
            e.mixerVisible.toggle()

        // ===== Outputs
        case "startstreaming":
            e.setOutputs(kind: .stream, running: true, filter: streamFilter(value))
        case "stopstreaming":
            e.setOutputs(kind: .stream, running: false, filter: streamFilter(value))
        case "startstopstreaming":
            let on = e.outputs.contains { $0.config.kind == .stream && $0.running && (streamFilter(value)?($0) ?? true) }
            e.setOutputs(kind: .stream, running: !on, filter: streamFilter(value))
        case "startsrtoutput", "stopsrtoutput", "startstopsrtoutput":
            let filter: (OutputChannel) -> Bool = { o in
                o.config.proto == .srt && (Int(value).map { o.config.bus == $0 } ?? true)
            }
            let on: Bool
            switch fn {
            case "startsrtoutput": on = true
            case "stopsrtoutput": on = false
            default: on = !e.outputs.contains { $0.config.kind == .stream && $0.running && filter($0) }
            }
            guard e.outputs.contains(where: { $0.config.kind == .stream && filter($0) }) else { return "No SRT output configured" }
            e.setOutputs(kind: .stream, running: on, filter: filter)
        case "streamingseturl", "streamingsetkey", "streamingsetusername", "streamingsetpassword":
            return streamingSet(fn, value, e)
        case "startrecording":
            e.setOutputs(kind: .record, running: true)
        case "stoprecording":
            e.setOutputs(kind: .record, running: false)
        case "startstoprecording":
            e.setOutputs(kind: .record, running: !e.anyRunning(kind: .record))
        case "startexternal":
            e.setOutputs(kind: .ndi, running: true)
            e.setOutputs(kind: .decklink, running: true)
        case "stopexternal":
            e.setOutputs(kind: .ndi, running: false)
            e.setOutputs(kind: .decklink, running: false)
        case "startstopexternal":
            let on = e.anyRunning(kind: .ndi) || e.anyRunning(kind: .decklink)
            e.setOutputs(kind: .ndi, running: !on)
            e.setOutputs(kind: .decklink, running: !on)
        case "startmulticorder":
            e.startMultiCorder()
        case "stopmulticorder":
            e.stopMultiCorder()
        case "startstopmulticorder":
            if e.multiCorderOn { e.stopMultiCorder() } else { e.startMultiCorder() }
        case "fullscreen":
            FullscreenOutput.shared.toggle(engine: e)
        case "fullscreenon":
            FullscreenOutput.shared.show(engine: e)
        case "fullscreenoff":
            FullscreenOutput.shared.hide()
        case "setoutputfullscreen", "setoutputfullscreen2":
            if let b = busNumber(value), b >= 2 {
                FullscreenOutput.shared.setSource(e.busSources[b - 2], engine: e)
            } else if let src = busSource(value, input: input) {
                FullscreenOutput.shared.setSource(src, engine: e)
            } else {
                return "Value=Output|Preview|MultiView|Clean|Input|Output2…4"
            }
        case "setoutputexternal2":
            guard let b = busNumber(value) else { return "Value=Output|Output2|Output3|Output4" }
            let ext = e.outputs.filter { $0.config.kind == .ndi || $0.config.kind == .decklink }
            guard ext.count >= 2 else { return "Second NDI/DeckLink output not configured" }
            ext[1].config.bus = b
        case "snapshot":
            return e.snapshot(path: value.isEmpty ? nil : value) == nil ? "Snapshot failed" : nil
        // ===== Data Sources (vMix: DataSourceSelectRow Value=Name,Table,Index · Next/PreviousRow Value=Name,Table)
        case "datasourceselectrow", "datasourcenextrow", "datasourcepreviousrow", "datasourceautonexton",
             "datasourceautonextoff", "datasourceautonextonoff":
            let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let n = parts.first, let src = e.dataSources.source(named: n) else { return "Data source not found" }
            switch fn {
            case "datasourceselectrow":
                guard let idx = parts.last.flatMap({ Int($0) }) else { return "Value=Name,Table,Index" }
                e.dataSources.select(src, row: idx)
            case "datasourcenextrow": e.dataSources.step(src, by: 1)
            case "datasourcepreviousrow": e.dataSources.step(src, by: -1)
            case "datasourceautonexton": src.config.autoNext = true
            case "datasourceautonextoff": src.config.autoNext = false
            default: src.config.autoNext.toggle()
            }
        case "setlayer", "setmultiviewoverlay":   // vMix: Input=target Value="LayerNumber,InputRef" (empty ref clears)
            guard let i = input else { return needInput() }
            let parts = value.split(separator: ",", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let n = Int(parts.first ?? ""), (1...10).contains(n) else { return "Value=LayerNumber,Input" }
            let ref = parts.count > 1 ? resolveInput(parts[1], e)?.id : nil
            while i.layers.count < n { i.layers.append(InputLayer(x: 0.6, y: 0.6, w: 0.3, h: 0.3)) }
            i.layers[n - 1].inputID = ref
        case "multiviewoverlayon", "multiviewoverlayoff", "multiviewoverlay":   // Value=LayerNumber
            guard let i = input, let n = Int(value), i.layers.indices.contains(n - 1) else { return "Input / Value=LayerNumber" }
            i.layers[n - 1].visible = fn == "multiviewoverlayon" ? true : (fn == "multiviewoverlayoff" ? false : !i.layers[n - 1].visible)
        case "layerlayout":       // BraceletMix extension: Input=target Value=quad|nine|split2|onePlus3|pipBR …
            if value.lowercased() == "none", let i = input { i.layers = []; return nil }
            guard let i = input, let layout = LayerLayout(rawValue: value) else { return "Value=" + LayerLayout.allCases.map(\.rawValue).joined(separator: "|") }
            let rects = layout.rects(gap: 0.01)
            var out: [InputLayer] = []
            for (k, r) in rects.enumerated() {
                var l = k < i.layers.count ? i.layers[k] : InputLayer(x: 0, y: 0, w: 0, h: 0)
                l.x = r.0; l.y = r.1; l.w = r.2; l.h = r.3; l.fill = r.4
                out.append(l)
            }
            var pool = e.inputs.filter { c in c.id != i.id && c.kind != .audio && !out.contains { $0.inputID == c.id } }
            for k in out.indices where out[k].inputID == nil && !pool.isEmpty { out[k].inputID = pool.removeFirst().id }
            i.layers = out
        // List input (vMix List): NextItem / PreviousItem / SelectIndex Value=n (1-based) / ListAdd / ListRemove …
        case "nextitem":
            guard let f = input as? FFmpegInput else { return needInput() }
            f.nextItem()
        case "previousitem":
            guard let f = input as? FFmpegInput else { return needInput() }
            f.previousItem()
        case "selectindex":
            guard let f = input as? FFmpegInput, let n = Int(value) else { return "List input + Value=n" }
            f.selectItem(n - 1, play: f.playing)
        case "listadd":
            guard let f = input as? FFmpegInput, !value.isEmpty else { return "List input + Value=path" }
            f.addItems([(value as NSString).expandingTildeInPath])
        case "listremove":
            guard let f = input as? FFmpegInput, let n = Int(value) else { return "List input + Value=n" }
            f.removeItem(n - 1)
        case "listremoveall":
            guard let f = input as? FFmpegInput else { return needInput() }
            f.playlist = f.playlist.indices.contains(f.playlistIndex) ? [f.playlist[f.playlistIndex]] : []
        case "listshuffle":
            guard let f = input as? FFmpegInput else { return needInput() }
            f.shuffleList()
        // HongMix auto ducking
        case "duckingon": e.ducking.enabled = true
        case "duckingoff": e.ducking.enabled = false
        case "setducktrigger", "setducked":      // Input=…, Value=On/Off
            guard let i = input else { return needInput() }
            let on = value.isEmpty || ["on", "true", "1"].contains(value.lowercased())
            if fn == "setducktrigger" { i.audioFX.duckTrigger = on } else { i.audioFX.ducked = on }
        case "setrecordaudiotracks":   // HongMix multitrack: Value=buses for extra tracks, e.g. "AB" ("" = off)
            let v = AudioBus.all.filter { value.uppercased().contains($0) }.joined()
            for o in e.outputs where o.config.kind == .record { o.config.extraAudioBuses = v }
        // LUT
        case "setlut":            // Input=…, Value=/path/file.cube ("" = off)
            guard let i = input else { return needInput() }
            i.lutPath = (value as NSString).expandingTildeInPath
        case "setlutstrength":    // Value=0…1
            guard let i = input, let v = Float(value) else { return "Input + Value=0…1" }
            i.lutStrength = max(0, min(1, v))
        case "rundownnext":       // HongMix rundown: NEXT / PREVIOUS / GO Value=n (1-based) / RESET
            e.rundown.next(e)
        case "rundownprevious":
            e.rundown.previous(e)
        case "rundowngo":
            guard let n = Int(value) else { return "Value=item number" }
            e.rundown.go(n - 1, e)
        case "rundownreset":
            e.rundown.reset()
        case "setdelay":          // HongMix: Value=seconds — broadcast delay of stream + record outputs (applies on next start)
            guard let sec = Int(value), sec >= 0 else { return "Value=seconds" }
            for o in e.outputs where o.config.kind == .stream || o.config.kind == .record { o.config.delaySeconds = sec }
        case "delaydump":         // HongMix: dump the broadcast delay of every running delayed output
            for o in e.outputs where o.running && o.config.delaySeconds > 0 { o.dumpDelay() }
        case "scheduleadd":       // BraceletMix extension: Value="HH:MM[:SS],Function[,Input[,Value]]" (daily)
            let parts = value.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
            let t = (parts.first ?? "").split(separator: ":").compactMap { Int($0) }
            guard parts.count >= 2, t.count >= 2, (0...23).contains(t[0]), (0...59).contains(t[1]) else { return "Value=HH:MM[:SS],Function[,Input[,Value]]" }
            var a = ScheduledAction()
            a.hour = t[0]; a.minute = t[1]; a.second = t.count > 2 ? min(59, max(0, t[2])) : 0
            a.function = parts[1]
            if parts.count > 2 { a.input = parts[2] }
            if parts.count > 3 { a.value = parts[3] }
            a.name = q["selectedname"] ?? ""
            e.scheduler.actions.append(a)
        case "scheduleremove":    // BraceletMix extension: Value=name or index (1-based); empty = all
            if value.isEmpty { e.scheduler.actions.removeAll() }
            else if let n = Int(value), n >= 1, n <= e.scheduler.actions.count { e.scheduler.actions.remove(at: n - 1) }
            else { e.scheduler.actions.removeAll { $0.name == value } }
        case "loudnessreset":     // BraceletMix extension: restart the integrated (R128) measurement
            e.audioMixer.loudness.reset()
        case "setbackupinput":    // BraceletMix extension: Input=live input, Value=backup input ("" = none)
            guard let i = input else { return needInput() }
            i.backupInputID = value.isEmpty ? nil : resolveInput(value, e)?.id
        case "datasourceadd":     // BraceletMix extension: Value="Name,URL-or-path"
            let parts = value.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return "Value=Name,URL" }
            e.dataSources.add(DataSourceConfig(name: parts[0], url: parts[1]))
        case "datasourcebind":    // BraceletMix extension: Input=title SelectedName=field Value="Name,ColumnIndex"
            let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let t = title, let f = q["selectedname"], parts.count == 2, let col = Int(parts[1]),
                  let src = e.dataSources.source(named: parts[0]) else { return "Input, SelectedName, Value=Name,Column" }
            e.dataSources.bindings.append(DataBinding(inputID: t.id, fieldID: f, sourceID: src.id, column: col))
            e.dataSources.apply()
        case "snapshotwindow":   // BraceletMix extension: PNG of the main window (UI layout check)
            return snapshotWindow(value) ? nil : "Snapshot failed"
        case "resizewindow":     // BraceletMix extension: Value=width,height
            let p = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard p.count == 2, let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) }) else { return "Value=width,height" }
            w.setContentSize(NSSize(width: p[0], height: p[1]))
            return nil
        case "snapshotinput":
            guard let i = input else { return needInput() }
            return e.snapshot(input: i, path: value.isEmpty ? nil : value) == nil ? "Snapshot failed" : nil

        default:
            if unsupportedPrefixes.contains(where: { fn.hasPrefix($0) }) {
                return "Not supported in HongMix: \(function)"
            }
            return "Function not found: \(function)"
        }
        return nil
    }

    /// "transition3" with prefix "transition" -> 3 (1…4)
    private static func numberSuffix(_ fn: String, _ prefix: String) -> Int? {
        guard fn.hasPrefix(prefix) else { return nil }
        let rest = fn.dropFirst(prefix.count)
        guard rest.count == 1, let n = Int(rest), (1...4).contains(n) else { return nil }
        return n
    }

    private enum BusAction { case toggle, on, off, volume, sendToggle, sendOn, sendOff, soloToggle, soloOn, soloOff }

    /// Matches BusAAudio/BusAAudioOn/Off, BusXAudio (Value=A), BusXSendToMaster…, BusXSolo…, SetBusAVolume.
    private static func busFunction(_ fn: String) -> (bus: Int?, action: BusAction)? {
        if fn.hasPrefix("setbus"), fn.hasSuffix("volume") {
            let mid = String(fn.dropFirst(6).dropLast(6))
            return (busIndex(mid), .volume)
        }
        guard fn.hasPrefix("bus") else { return nil }
        let rest = String(fn.dropFirst(3))
        guard let letter = rest.first else { return nil }
        let explicitBus: Int? = letter == "x" ? nil : busIndex(String(letter))
        if letter != "x" && explicitBus == nil { return nil }
        let tail = String(rest.dropFirst())
        let action: BusAction
        switch tail {
        case "audio": action = .toggle
        case "audioon": action = .on
        case "audiooff": action = .off
        case "sendtomaster": action = .sendToggle
        case "sendtomasteron": action = .sendOn
        case "sendtomasteroff": action = .sendOff
        case "solo": action = .soloToggle
        case "soloon": action = .soloOn
        case "solooff": action = .soloOff
        default: return nil
        }
        return (explicitBus ?? -1, action)
    }

    private static func performBus(_ bus: Int?, _ action: BusAction, _ value: String, _ e: SwitcherEngine) -> String? {
        var b = bus ?? -1
        if b < 0 {
            // BusX… functions take the bus letter in Value
            guard let v = busIndex(value) else { return "Value=A…G required" }
            b = v
        }
        guard (0..<AudioMixer.busCount).contains(b) else { return "Unknown bus" }
        switch action {
        case .toggle: e.busSettings[b].muted.toggle()
        case .on: e.busSettings[b].muted = false
        case .off: e.busSettings[b].muted = true
        case .volume:
            guard let v = Float(value) else { return "Value required" }
            e.setBusVolume(b, v / 100)
        case .sendToggle: e.busSettings[b].sendToMaster.toggle()
        case .sendOn: e.busSettings[b].sendToMaster = true
        case .sendOff: e.busSettings[b].sendToMaster = false
        case .soloToggle: e.busSettings[b].solo.toggle()
        case .soloOn: e.busSettings[b].solo = true
        case .soloOff: e.busSettings[b].solo = false
        }
        return nil
    }

    private static func applyCC(_ fn: String, _ v: Float, _ i: InputSource) {
        var a = i.adjust
        let ch = fn.hasSuffix("rgb") ? "rgb" : String(fn.last!)
        func set(_ r: inout Float, _ g: inout Float, _ b: inout Float, _ value: Float) {
            if ch == "rgb" || ch == "r" { r = value }
            if ch == "rgb" || ch == "g" { g = value }
            if ch == "rgb" || ch == "b" { b = value }
        }
        if fn.contains("gain") {
            set(&a.gainR, &a.gainG, &a.gainB, max(0, min(4, v)))
        } else if fn.contains("gamma") {
            set(&a.gammaR, &a.gammaG, &a.gammaB, max(0.1, min(4, v)))
        } else {
            set(&a.liftR, &a.liftG, &a.liftB, max(-1, min(1, v)))
        }
        i.adjust = a
    }

    private static func titleField(_ fn: String, _ t: TitleInput, _ q: [String: String], _ value: String) -> String? {
        let name = q["selectedname"]
        let index = q["selectedindex"].flatMap { Int($0) }
        let isImage = fn.hasPrefix("setimage")
        let idxOpt = isImage ? t.imageFieldIndex(name: name, index: index) :
            (fn == "setcolor" || fn == "setcolour") ? t.fieldIndex(name: name ?? "Background.Fill", index: nil) :
            t.fieldIndex(name: name, index: index)
        guard let idx = idxOpt else { return "Field not found" }
        var doc = t.document
        switch fn {
        case "settext": doc.fields[idx].text = value
        case "settextcolour", "settextcolor", "setcolor", "setcolour": doc.fields[idx].color = colorValue(value)
        case "settextvisible", "setimagevisible": doc.fields[idx].visible.toggle()
        case "settextvisibleon", "setimagevisibleon": doc.fields[idx].visible = true
        case "settextvisibleoff", "setimagevisibleoff": doc.fields[idx].visible = false
        case "setimage": doc.fields[idx].imagePath = value
        default: return "Unknown title function"
        }
        t.document = doc
        return nil
    }

    private static let namedColors: [String: String] = [
        "white": "#FFFFFF", "black": "#000000", "red": "#FF0000", "green": "#00C000", "blue": "#0050FF",
        "yellow": "#FFD000", "orange": "#FF8000", "gray": "#808080", "grey": "#808080", "transparent": "#00000000",
    ]

    private static func colorValue(_ v: String) -> String {
        let s = v.trimmingCharacters(in: .whitespaces)
        if let named = namedColors[s.lowercased()] { return named }
        return s.hasPrefix("#") ? s : "#" + s
    }

    private static func streamFilter(_ value: String) -> ((OutputChannel) -> Bool)? {
        guard let idx = Int(value) else { return nil }
        return { o in o.config.bus == idx + 1 || o.config.name.hasSuffix("\(idx)") }
    }

    /// StreamingSetURL / Key / Username / Password. Value = "text" or "index,text" (0-based stream output).
    private static func streamingSet(_ fn: String, _ value: String, _ e: SwitcherEngine) -> String? {
        if !e.outputs.contains(where: { $0.config.kind == .stream }) {
            e.addOutput(OutputConfig.defaultConfig(kind: .stream))
        }
        let streams = e.outputs.filter { $0.config.kind == .stream }
        var idx = 0
        var text = value
        if let comma = value.firstIndex(of: ","), let n = Int(value[..<comma]) {
            idx = n
            text = String(value[value.index(after: comma)...])
        }
        guard streams.indices.contains(idx) else { return "Stream index out of range" }
        let o = streams[idx]
        switch fn {
        case "streamingseturl":
            if text.lowercased().hasPrefix("srt://") {
                o.config.proto = .custom
                o.config.customURL = text
            } else {
                o.config.proto = .rtmp
                o.config.rtmpServer = text
            }
        case "streamingsetkey": o.config.streamKey = text
        case "streamingsetusername": o.config.rtmpUsername = text
        default: o.config.rtmpPassword = text
        }
        return nil
    }

    /// AddInput Value="Type|Path", e.g. "Video|/Users/me/a.mp4", "Image|…", "Colour|#FF0000", "NDI|MACHINE (Src)",
    /// "Stream|srt://…", "Title|LowerThird"
    private static func addInput(_ value: String, _ e: SwitcherEngine) -> String? {
        let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "Value=Type|Path" }
        let type = parts[0].lowercased(), arg = parts[1]
        var c: InputConfig
        switch type {
        case "video", "audiofile", "media":
            c = InputConfig(kind: .media, name: (arg as NSString).lastPathComponent)
            c.url = arg
        case "image", "photos":
            c = InputConfig(kind: .image, name: (arg as NSString).lastPathComponent)
            c.imagePath = arg
        case "colour", "color":
            c = InputConfig(kind: .color, name: "Colour")
            c.color = arg
        case "ndi":
            c = InputConfig(kind: .ndi, name: arg)
            c.ndiSource = arg
        case "stream", "srt", "rtmp":
            c = InputConfig(kind: .stream, name: arg)
            c.url = arg
        case "browser", "web", "webbrowser":
            c = InputConfig(kind: .browser, name: arg)
            c.browserURL = arg
        case "desktopcapture", "screen":
            c = InputConfig(kind: .screen, name: "Desktop Capture")
            c.screenDisplayID = UInt32(arg) ?? 0
        case "audio", "audioinput":
            c = InputConfig(kind: .audio, name: arg.isEmpty ? "Audio" : arg)
            c.audioDeviceID = CameraInput.audioDevices().first { $0.localizedName == arg || $0.uniqueID == arg }?.uniqueID ?? ""
        case "title", "gt", "xaml":
            let t = TitleTemplate.allCases.first { $0.rawValue.caseInsensitiveCompare(arg) == .orderedSame } ?? .lowerThird
            c = InputConfig(kind: .title, name: t.label)
            c.title = TitleDocument(template: t)
        default:
            return "Unsupported input type \(parts[0])"
        }
        e.addInput(c)
        return nil
    }

    private static func snapshotWindow(_ path: String) -> Bool {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
              let v = w.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
        v.cacheDisplay(in: v.bounds, to: rep)
        // Metal monitors aren't captured by cacheDisplay: paint their current frames in (aspect-fit, like on screen)
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            let ci = CIContext()
            func walk(_ view: NSView) {
                if let m = view as? MonitorLayerView, let pb = m.renderer?.source(), !m.isHiddenOrHasHiddenAncestor {
                    var r = m.convert(m.bounds, to: v)
                    if v.isFlipped { r.origin.y = v.bounds.height - r.maxY }     // CG context is bottom-left
                    let img = CIImage(cvPixelBuffer: pb)
                    if let cg = ci.createCGImage(img, from: img.extent) {
                        let ia = img.extent.width / max(1, img.extent.height)
                        var fit = r
                        if r.width / max(1, r.height) > ia { fit.size.width = r.height * ia; fit.origin.x = r.midX - fit.width / 2 }
                        else { fit.size.height = r.width / ia; fit.origin.y = r.midY - fit.height / 2 }
                        let cgc = ctx.cgContext
                        cgc.setFillColor(CGColor(gray: 0, alpha: 1)); cgc.fill(r)
                        cgc.draw(cg, in: fit)
                    }
                }
                view.subviews.forEach(walk)
            }
            walk(v)
            NSGraphicsContext.restoreGraphicsState()
        }
        let file = path.isEmpty ? (("~/Pictures/BraceletMix/window.png") as NSString).expandingTildeInPath
                                : (path as NSString).expandingTildeInPath
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: file))) != nil
    }

    // MARK: - XML state

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func tf(_ b: Bool) -> String { b ? "True" : "False" }

    static func typeName(_ k: InputKind) -> String {
        switch k {
        case .camera, .decklink: return "Capture"
        case .media: return "Video"
        case .stream: return "Stream"
        case .ndi: return "NDI"
        case .color: return "Colour"
        case .image: return "Image"
        case .title: return "GT"
        case .screen: return "DesktopCapture"
        case .browser: return "Browser"
        case .audio: return "Audio"
        }
    }

    /// XML state using the same element/attribute layout as the vMix Web API, so existing
    /// control surfaces (e.g. Bitfocus Companion's vMix module) can read it.
    static func stateXML(_ e: SwitcherEngine) -> String {
        var x = "<vmix>"
        // version is reported for protocol compatibility with existing control surfaces
        x += "<version>27.0.0.0</version><edition>HongMix</edition><preset></preset>"
        x += "<format>\(esc(e.format.name))</format>"
        x += "<inputs>"
        for (idx, i) in e.inputs.enumerated() {
            let m = e.audioMixer.meter(for: i.id)
            let state = i.supportsTransport ? (i.playing ? "Running" : "Paused") : "Running"
            let busList = AudioBus.letters(i.buses).map { String($0) }.joined(separator: ",")
            x += "<input key=\"\(i.id.uuidString.lowercased())\" number=\"\(idx + 1)\" type=\"\(typeName(i.kind))\" "
            x += "title=\"\(esc(i.name))\" shortTitle=\"\(esc(i.name))\" state=\"\(state)\" "
            x += "position=\"\(Int(i.position * 1000))\" duration=\"\(Int(i.duration * 1000))\" "
            if i.markIn >= 0 { x += "markIn=\"\(Int(i.markIn * 1000))\" " }
            if i.markOut > 0 { x += "markOut=\"\(Int(i.markOut * 1000))\" " }
            x += "loop=\"\(tf(i.looping))\" muted=\"\(tf(i.muted))\" volume=\"\(Int((i.volume * 100).rounded()))\" "
            x += "balance=\"\(i.balance)\" solo=\"\(tf(i.solo))\" soloPFL=\"\(tf(i.solo))\" audiobusses=\"\(busList)\" "
            x += "gainDb=\"\(i.gainDB)\" audioauto=\"\(tf(i.audioFollowsVideo))\" "
            if let f = i as? FFmpegInput, f.isList { x += "selectedIndex=\"\(f.playlistIndex + 1)\" " }
            x += "hmState=\"\(i.state)\" hmStatus=\"\(esc(i.status))\" "
            if !i.lutPath.isEmpty {
                let st = LUTCache.shared.error(i.lutPath) ?? (LUTCache.shared.isLoaded(i.lutPath) ? "loaded" : "loading")
                x += "lut=\"\(esc(i.lutPath))\" lutState=\"\(esc(st))\" lutApplied=\"\(tf(i.composed != nil))\" "
            }
            x += String(format: "meterF1=\"%.4f\" meterF2=\"%.4f\"", m.0, m.1)
            x += ">\(esc(i.name))"
            if let t = i as? TitleInput {
                var ti = 0, ii = 0
                for f in t.document.fields {
                    switch f.kind {
                    case .text:
                        x += "<text index=\"\(ti)\" name=\"\(esc(f.id))\">\(esc(t.displayText(f)))</text>"
                        ti += 1
                    case .image:
                        x += "<image index=\"\(ii)\" name=\"\(esc(f.id))\">\(esc(f.imagePath))</image>"
                        ii += 1
                    case .shape:
                        break
                    }
                }
            }
            if let f = i as? FFmpegInput, f.isList {
                x += "<list>"
                for (k, item) in f.playlist.enumerated() {
                    x += k == f.playlistIndex ? "<item selected=\"true\">\(esc(item))</item>" : "<item>\(esc(item))</item>"
                }
                x += "</list>"
            }
            let a = i.adjust
            if a != VideoAdjust() {
                x += String(format: "<position panX=\"%.3f\" panY=\"%.3f\" zoomX=\"%.3f\" zoomY=\"%.3f\" />",
                            a.panX, a.panY, a.zoom, a.zoom)
            }
            x += "</input>"
        }
        x += "</inputs><overlays>"
        for c in 0..<SwitcherEngine.overlayCount {
            let n = e.overlayOn[c] ? e.number(ofID: e.overlayIDs[c]) : 0
            x += n > 0 ? "<overlay number=\"\(c + 1)\">\(n)</overlay>" : "<overlay number=\"\(c + 1)\" />"
        }
        x += "</overlays>"
        x += "<preview>\(e.number(ofID: e.previewID))</preview><active>\(e.number(ofID: e.programID))</active>"
        x += "<fadeToBlack>\(tf(e.ftbOn))</fadeToBlack><transitions>"
        for (i, t) in e.transitionSlots.enumerated() {
            x += "<transition number=\"\(i + 1)\" effect=\"\(t.type.label)\" duration=\"\(t.durationMs)\" />"
        }
        x += "</transitions>"
        x += "<recording>\(tf(e.anyRunning(kind: .record)))</recording>"
        x += "<external>\(tf(e.anyRunning(kind: .ndi) || e.anyRunning(kind: .decklink)))</external>"
        x += "<streaming>\(tf(e.anyRunning(kind: .stream)))</streaming>"
        x += "<playList>False</playList><multiCorder>\(tf(e.multiCorderOn))</multiCorder>"
        x += "<fullscreen>\(tf(FullscreenOutput.shared.isShowing))</fullscreen>"
        x += "<audio>"
        for b in 0..<AudioMixer.busCount {
            let s = e.busSettings[b]
            let m = e.audioMixer.busMeter(b)
            let tag = b == 0 ? "master" : "bus\(AudioBus.all[b])"
            x += "<\(tag) volume=\"\(Int((s.volume * 100).rounded()))\" muted=\"\(tf(s.muted))\" "
            x += String(format: "meterF1=\"%.4f\" meterF2=\"%.4f\" ", m.0, m.1)
            if b == 0 {
                x += "headphonesVolume=\"\(Int((e.headphonesVolume * 100).rounded()))\" />"
            } else {
                x += "sendToMaster=\"\(tf(s.sendToMaster))\" solo=\"\(tf(s.solo))\" />"
            }
        }
        x += "</audio><message>\(esc(e.lastMessage))</message>"
        x += "<dataSources>"
        for d in e.dataSources.sources {
            x += "<dataSource name=\"\(esc(d.config.name))\" rows=\"\(d.rows.count)\" row=\"\(d.config.row + 1)\" status=\"\(esc(d.status))\" />"
        }
        x += "</dataSources>"
        // BraceletMix diagnostics (ignored by vMix clients)
        for i in e.inputs {
            let st = i.video.stats
            x += String(format: "<inputStats number=\"%d\" fps=\"%.2f\" measuredFps=\"%.2f\" jitterMs=\"%.2f\" late=\"%d\" w=\"%d\" h=\"%d\" status=\"%@\" sourceDropped=\"%d\" signalLost=\"%@\" />",
                        e.number(of: i), st.fps, st.updateFPS, st.jitterMs, st.late, st.width, st.height, esc(i.status), i.video.sourceDropped,
                        tf(i.signalLost))
        }
        for i in e.inputs {
            if let st = (i as? FFmpegInput)?.srtStats() {
                x += String(format: "<srtStats input=\"%d\" mode=\"%@\" peer=\"%@\" rttMs=\"%.1f\" rateMbps=\"%.2f\" lossPct=\"%.2f\" lost=\"%lld\" retrans=\"%lld\" dropped=\"%lld\" bufferMs=\"%d\" latencyMs=\"%d\" />",
                            e.number(of: i), st.mode, st.peer, st.rttMs, st.rateMbps, st.lossPercent, st.lost, st.retransmitted, st.dropped, st.bufferMs, st.latencyMs)
            }
        }
        for o in e.outputs {
            if let st = o.srtStats() {
                x += String(format: "<srtStats output=\"%@\" mode=\"%@\" peer=\"%@\" rttMs=\"%.1f\" rateMbps=\"%.2f\" lossPct=\"%.2f\" lost=\"%lld\" retrans=\"%lld\" dropped=\"%lld\" bufferMs=\"%d\" latencyMs=\"%d\" />",
                            esc(o.config.name), st.mode, st.peer, st.rttMs, st.rateMbps, st.lossPercent, st.lost, st.retransmitted, st.dropped, st.bufferMs, st.latencyMs)
            }
        }
        for o in e.outputs where o.running {
            x += "<outputStats name=\"\(esc(o.config.name))\" kind=\"\(o.config.kind.rawValue)\" stats=\"\(esc(o.statsText))\" delayMs=\"\(o.delayBufferedMs)\" dumped=\"\(tf(o.delayDumped))\" file=\"\(esc(o.lastFile))\" />"
        }
        for b in e.inputs.compactMap({ $0 as? BrowserInput }) {
            let st = b.video.stats
            x += String(format: "<browserCapture title=\"%@\" mode=\"%@\" updateFps=\"%.1f\" engine=\"%@\" />",
                        esc(b.name), b.captureMode, st.updateFPS, String(cString: mc_web_version()))
        }
        x += String(format: "<renderStats avgMs=\"%.2f\" maxMs=\"%.2f\" dropped=\"%d\" uiStallMs=\"%.0f\" outputMonitorFps=\"%d\" uiUpdates=\"%@\" slowTick=\"%@\" />",
                    e.renderMs, e.renderMsPeak, e.droppedTicks, e.uiStallMs, MonitorRenderer.drawsPerSecond, esc(e.uiUpdateReport), esc(e.slowTickReport))
        x += "<schedule>"
        let now = Date()
        let iso = ISO8601DateFormatter()
        for (k, a) in e.scheduler.actions.enumerated() {
            x += "<action index=\"\(k + 1)\" name=\"\(esc(a.name))\" enabled=\"\(tf(a.enabled))\" time=\"\(a.timeText)\" days=\"\(a.weekdays.map(String.init).joined(separator: ","))\" function=\"\(esc(a.function))\" input=\"\(esc(a.input))\" value=\"\(esc(a.value))\" next=\"\(a.nextFire(after: now).map { iso.string(from: $0) } ?? "")\" lastFired=\"\(a.lastFired.map { iso.string(from: $0) } ?? "")\" />"
        }
        x += "</schedule>"
        let lr = e.audioMixer.loudness.current
        func lf(_ v: Double) -> String { v.isFinite ? String(format: "%.1f", v) : "-inf" }
        x += "<loudness momentary=\"\(lf(lr.momentary))\" shortTerm=\"\(lf(lr.shortTerm))\" integrated=\"\(lf(lr.integrated))\" range=\"\(lf(lr.range))\" peak=\"\(lf(lr.peak))\" target=\"\(lf(LoudnessTarget.saved.rawValue))\" seconds=\"\(Int(lr.seconds))\" />"
        x += "</vmix>"
        return x
    }

    /// "0121..." — one digit per input: 0 off, 1 program, 2 preview.
    static func tallyString(_ e: SwitcherEngine) -> String {
        e.inputs.map { String(e.tally(of: $0)) }.joined()
    }
}
