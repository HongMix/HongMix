import Foundation
import CoreVideo

/// Web remote (`/`) and camera tally (`/tally`) served by the HTTP API (port 8088), plus the small JSON
/// states they poll (`/remote.json`, `/tally.json`). The remote is the switcher moved into a browser: the
/// same PREVIEW · transition column · PROGRAM · input tiles · Audio Mixer layout and labels as the app,
/// re-arranged for laptop / iPad / phone widths (page: `WebRemotePage.swift`).
///
/// Access: both need remote control on (Settings › Network). The tally page and `/tally.json` are
/// view-only and are served without the HTTP password (IP rules still apply), so camera operators
/// can see their light without being able to switch; everything else asks for the password if one is set.
enum WebRemote {
    /// Paths served without the HTTP password (read-only tally).
    static let publicPaths: Set<String> = ["/tally", "/tally/", "/tally.txt", "/tally.json"]

    // MARK: JSON states

    private static func num(_ d: Double, _ scale: Double = 1000) -> Double {
        d.isFinite ? (d * scale).rounded() / scale : 0
    }

    static func json(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Number of the input on each overlay channel while it is on air (0 = off).
    private static func overlays(_ e: SwitcherEngine) -> [Int] {
        (0..<SwitcherEngine.overlayCount).map { e.overlayOn[$0] ? e.number(ofID: e.overlayIDs[$0]) : 0 }
    }

    /// Everything the remote page shows (no file paths, addresses or keys).
    static func remoteState(_ e: SwitcherEngine) -> String {
        var inputs: [[String: Any]] = []
        for (k, i) in e.inputs.enumerated() {
            let m = e.audioMixer.meter(for: i.id)
            var d: [String: Any] = [
                "n": k + 1, "title": i.name, "type": APIProcessor.typeName(i.kind), "tally": e.tally(of: i),
                "muted": i.muted, "volume": Int((i.volume * 100).rounded()),
                "m1": num(Double(m.0)), "m2": num(Double(m.1)),
                "audio": !(i.kind == .color || i.kind == .image || i.kind == .title),
            ]
            if i.supportsTransport {
                d["media"] = true
                d["playing"] = i.playing
                d["loop"] = i.looping
                d["pos"] = num(i.position, 10)
                d["dur"] = num(i.duration, 10)
            }
            if let deck = i as? SlideDeckInput {  // PDF / PowerPoint / Photos: 1-based slide, count (2.3.3)
                d["slide"] = deck.count > 0 ? deck.currentIndex + 1 : 0
                d["slides"] = deck.count
            }
            if let t = i as? TitleInput {
                let doc = t.document
                d["fields"] = doc.fields.filter { $0.kind == .text && ($0.mode == .plain || $0.mode == .ticker) }
                    .map { ["name": $0.id, "text": t.displayText($0)] }
                d["presets"] = doc.presets.count
                d["preset"] = doc.selectedPreset
                if doc.fields.contains(where: { $0.kind == .text && $0.mode == .countdown }) {
                    let c = t.countdownStatus
                    d["cd"] = num(c.remaining, 10)
                    d["cdRun"] = c.running && !c.paused
                }
            }
            inputs.append(d)
        }
        func uptime(_ kinds: [OutputKind]) -> Double? {
            let up = e.outputs.filter { kinds.contains($0.config.kind) && $0.running && $0.state != Int32(MC_STATE_ERROR) }
                .compactMap(\.uptime)
            return up.max()
        }
        var srt: [[String: Any]] = []
        for (k, i) in e.inputs.enumerated() {
            guard let s = (i as? FFmpegInput)?.srtStats() else { continue }
            let link = e.srtMonitor.links.first { $0.id == "in:\(i.id)" }
            srt.append(["n": k + 1, "connected": s.connected, "rtt": num(s.rttMs, 10),
                        "loss": num(s.lossPercent, 100), "drops": link?.recentDrops ?? 0])
        }
        let master = e.busSettings[0]
        let mm = e.audioMixer.busMeter(0)
        let bank: [[String: Any]] = (0..<SwitcherEngine.overlayCount).map { c in
            ["on": e.overlayOn[c], "n": e.number(ofID: e.overlayIDs[c])]
        }
        var s: [String: Any] = [
            "format": e.format.name, "fps": num(e.format.fps, 100),
            "active": e.number(ofID: e.programID), "preview": e.number(ofID: e.previewID),
            "overlays": overlays(e), "bank": bank, "ftb": e.ftbOn, "tbar": num(e.tbar),
            "transitioning": e.transitioning,
            "trans": e.transitionSlots.map { ["effect": $0.type.label, "duration": $0.durationMs] },
            "renderMs": num(e.renderMs, 10), "renderMax": num(e.renderMsPeak, 10),
            "dropped": e.droppedTicks, "srt": srt, "inputs": inputs,
            "master": ["volume": Int((master.volume * 100).rounded()), "muted": master.muted,
                       "m1": num(Double(mm.0)), "m2": num(Double(mm.1))],
        ]
        for (key, kinds) in [("stream", [OutputKind.stream]), ("record", [.record]), ("external", [.ndi, .decklink])] {
            let has = e.outputs.contains { kinds.contains($0.config.kind) }
            if let up = uptime(kinds) { s[key] = ["on": true, "sec": Int(up), "has": has] } else { s[key] = ["on": false, "sec": 0, "has": has] }
        }
        return json(s)
    }

    /// Tally only: numbers, names, on air / preview. Thumbnails are offered only when no password is set
    /// (`/thumb` asks for it, and a password prompt for a picture would confuse the camera operator).
    static func tallyState(_ e: SwitcherEngine) -> String {
        let inputs: [[String: Any]] = e.inputs.enumerated().map { k, i in
            ["n": k + 1, "title": i.name, "tally": e.tally(of: i)]
        }
        return json(["active": e.number(ofID: e.programID), "preview": e.number(ofID: e.previewID),
                     "overlays": overlays(e), "inputs": inputs, "thumbs": APIAccess.password.isEmpty])
    }

    /// Picture for `/thumb`: `source=program` (the mixed output, overlays included), `source=preview`
    /// (composed preview, or the preview input), or `input=n`. Main thread.
    static func thumbBuffer(_ q: [String: String], _ e: SwitcherEngine) -> CVPixelBuffer? {
        switch q["source"]?.lowercased() {
        case "program", "output":
            return e.programSlot.latest()
        case "preview":
            if e.previewComposed, let pb = e.previewSlot.latest() { return pb }
            return e.input(withID: e.previewID)?.currentFrame()
        default:
            return APIProcessor.resolveInput(q["input"], e)?.currentFrame()
        }
    }

    // MARK: Pages

    /// Korean text and its English (Resources/en.json). The page switches language itself (한 / EN), so it
    /// gets both; checked by scripts/check-i18n.py like L().
    static func WL(_ ko: String) -> [String] { [ko, AppLanguage.english[ko] ?? ko] }

    static var appLang: String { AppLanguage.current == .en ? "en" : "ko" }

    static func fill(_ page: String, _ strings: [String: [String]]) -> String {
        let t = json(strings).replacingOccurrences(of: "</", with: "<\\/")
        return page.replacingOccurrences(of: "__LANG__", with: appLang).replacingOccurrences(of: "__T__", with: t)
    }

    static func tallyPage() -> String {
        fill(tallyHTML, [
            "pick": WL("탈리 — 입력 선택"), "loading": WL("불러오는 중…"), "change": WL("입력 바꾸기"),
            "none": WL("(없음)"), "lost": WL("연결 끊김"),
            "tap": WL("화면이 꺼지지 않게 하려면 한 번 탭하세요"),
        ]).replacingOccurrences(of: "__NOSLEEP__", with: noSleepVideo)
    }

    private static let tallyHTML = #"""
<!doctype html><html lang="__LANG__"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<title>HongMix Tally</title>
<style>
html,body{margin:0;height:100%;background:#111;color:#fff;font:600 18px -apple-system,system-ui,sans-serif}
#pick{padding:16px}#pick h1{font-size:18px;color:#aaa;display:flex;justify-content:space-between;align-items:center}
#lg{font-size:14px;background:#2a2a2e;color:#ddd;border:0;border-radius:8px;padding:6px 10px}
#pick .in{display:flex;align-items:center;gap:14px;width:100%;margin:8px 0;padding:12px;font-size:20px;border-radius:12px;border:0;background:#2a2a2e;color:#fff;text-align:left}
#pick img{flex:none;width:120px;aspect-ratio:16/9;object-fit:contain;background:#000;border-radius:6px}
#light{display:none;position:fixed;inset:0;align-items:center;justify-content:center;flex-direction:column;transition:background .08s}
#num{font-size:30vw;font-weight:800;line-height:1}#name{font-size:6vw;opacity:.85;margin-top:2vh;padding:0 4vw;text-align:center}
#state{position:fixed;top:3vh;font-size:5vw;letter-spacing:.2em}
#back{position:fixed;bottom:3vh;font-size:14px;opacity:.6;background:none;border:0;color:#fff}
#tap{display:none;position:fixed;bottom:9vh;font-size:14px;opacity:.75;padding:0 6vw;text-align:center}
.pgm{background:#d01818}.pvw{background:#14a83a}.off{background:#141414}
</style></head><body>
<div id="pick"><h1><span id="h"></span><button id="lg"></button></h1><div id="list"></div></div>
<div id="light"><div id="state"></div><div id="num"></div><div id="name"></div><div id="tap"></div><button id="back"></button></div>
<script>
const T=__T__;
const $=id=>document.getElementById(id);
function ls(k,v){try{if(v===undefined)return localStorage.getItem(k);localStorage.setItem(k,v)}catch(e){return null}}
let lang=ls('hmLang')||document.documentElement.lang;
const t=k=>T[k][lang=='en'?1:0];
function texts(){document.documentElement.lang=lang;$('h').textContent=t('pick');$('back').textContent=t('change');$('tap').textContent=t('tap');$('lg').textContent=lang=='en'?'한국어':'English';if(!sig)$('list').textContent=t('loading')}
let sel=+(new URLSearchParams(location.search).get('input')||ls('bmTally')||0),lock=null,vid=null,sig='';
$('lg').onclick=()=>{lang=lang=='en'?'ko':'en';ls('hmLang',lang);texts();sig='';tick()};
function fallback(){if(!vid){vid=document.createElement('video');vid.setAttribute('playsinline','');vid.setAttribute('muted','');vid.muted=true;vid.loop=true;
 vid.src='data:video/mp4;base64,__NOSLEEP__';vid.style.cssText='position:fixed;left:0;top:0;width:1px;height:1px;opacity:.01;pointer-events:none';
 vid.addEventListener('timeupdate',()=>{if(vid.currentTime>0.5)vid.currentTime=Math.random()*0.5});document.body.appendChild(vid)}
 const p=vid.play();if(p&&p.then)p.then(()=>{$('tap').style.display='none'}).catch(()=>{$('tap').style.display='block'})}
function keepAwake(){if(!sel)return;if(navigator.wakeLock&&window.isSecureContext){if(lock&&!lock.released)return;navigator.wakeLock.request('screen').then(l=>{lock=l;$('tap').style.display='none'}).catch(fallback)}else fallback()}
function sleepOK(){if(lock){lock.release().catch(()=>{});lock=null}if(vid)vid.pause();$('tap').style.display='none'}
function choose(n){sel=n;ls('bmTally',n);sig='';$('pick').style.display=n?'none':'block';$('light').style.display=n?'flex':'none';if(n)keepAwake();else sleepOK();tick()}
$('back').onclick=e=>{e.stopPropagation();choose(0)};$('light').onclick=keepAwake;
document.addEventListener('visibilitychange',()=>{if(!document.hidden)keepAwake()});
// one request at a time, 2-s timeout: an old reply can never overwrite a newer light, a dead link shows 'lost'
let ticking=false;function tick(){if(ticking)return;ticking=true;const c=new AbortController(),tm=setTimeout(()=>c.abort(),2000);
 fetch('/tally.json',{cache:'no-store',signal:c.signal}).then(r=>{if(!r.ok)throw 0;return r.json()}).then(s=>{
 if(!sel){const s2=s.inputs.map(i=>i.n+'\u0001'+i.title).join('\u0002')+s.thumbs+lang;if(s2==sig)return;sig=s2;const l=$('list');l.innerHTML='';
  s.inputs.forEach(i=>{const b=document.createElement('button');b.className='in';if(s.thumbs){const im=document.createElement('img');im.alt='';im.onerror=()=>im.style.visibility='hidden';im.src='/thumb?input='+i.n+'&width=240&t='+Date.now();b.appendChild(im)}
   b.appendChild(document.createTextNode(i.n+'. '+i.title));b.onclick=()=>choose(i.n);l.appendChild(b)});return}
 const me=s.inputs.find(i=>i.n==sel),k=me?me.tally:0;
 $('light').className=k==1?'pgm':k==2?'pvw':'off';$('state').textContent=k==1?'ON AIR':k==2?'PREVIEW':'';
 $('num').textContent=sel;$('name').textContent=me?me.title:t('none');
}).catch(()=>{$('state').textContent=t('lost');$('light').className='off'}).finally(()=>{clearTimeout(tm);ticking=false})}
texts();choose(sel);setInterval(tick,250);
</script></body></html>
"""#

    /// 2-second 64×64 black H.264 clip, played muted and inline to keep the phone screen on where the
    /// Wake Lock API isn't available (plain http on the LAN is not a "secure context").
    private static let noSleepVideo = "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAM0bW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAB9AAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAl90cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAB9AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAEAAAABAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAfQAAAAAAABAAAAAAHXbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAAAgABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABgm1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAUJzdGJsAAAAwnN0c2QAAAAAAAAAAQAAALJhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEAAQABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMiBsaWJ4MjY0AAAAAAAAAAAAAAAAGP//AAAAOGF2Y0MBZAAK/+EAGmdkAAqscgREJsBEAAADAAQAAAMACDxIlhGAAQAHaOhDjxMhMP34+AAAAAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAAALtAAAAAAAAAAYc3R0cwAAAAAAAAABAAAAAgAAQAAAAAAUc3RzcwAAAAAAAAABAAAAAQAAABxzdHNjAAAAAAAAAAEAAAABAAAAAgAAAAEAAAAcc3RzegAAAAAAAAAAAAAAAgAAAtwAAAARAAAAFHN0Y28AAAAAAAAAAQAAA2QAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYzLjEuMTAyAAAACGZyZWUAAAL1bWRhdAAAArEGBf//rdxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0xNiBkZWJsb2NrPTE6LTM6LTMgYW5hbHlzZT0weDM6MHgxMzMgbWU9dW1oIHN1Ym1lPTEwIHBzeT0xIHBzeV9yZD0yLjAwOjAuNzAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MjQgY2hyb21hX21lPTEgdHJlbGxpcz0yIDh4OGRjdD0xIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS00IHRocmVhZHM9MiBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTggYl9weXJhbWlkPTIgYl9hZGFwdD0yIGJfYmlhcz0wIGRpcmVjdD0zIHdlaWdodGI9MSBvcGVuX2dvcD0wIHdlaWdodHA9MiBrZXlpbnQ9MjUwIGtleWludF9taW49MSBzY2VuZWN1dD00MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTYwIHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMjAAgAAAACNliIEAAvnP/vfUt8yy7gcitguo96KcjIHuDBlRonyBvXtGzQAAAA1BmggtiC+c//7apqNA"
}
