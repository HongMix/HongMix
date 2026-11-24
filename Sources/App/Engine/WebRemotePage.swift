import Foundation

/// The web remote page (`/`). One page, three arrangements chosen by width (re-evaluated on rotate/resize):
///  - desk  (≥ 1100 px: laptop, desktop, iPad landscape): like the app — PREVIEW · transition column ·
///    PROGRAM, input tiles below, Audio Mixer / Titles panel on the right, REC · STREAM · EXTERNAL bar.
///  - tab   (700–1099 px: iPad portrait, small windows): PREVIEW | PROGRAM, transition strip, tiles;
///    Audio Mixer and Titles behind the bottom tabs.
///  - phone (< 700 px): small PREVIEW | PROGRAM, CUT · transition · FTB strip, 2-column tiles; Audio,
///    Titles and More (overlay bank, 4 transitions, T-Bar) behind the bottom tabs.
/// Touch devices get finger-sized buttons. Labels the app shows in English (PREVIEW, Quick Play, CUT,
/// Cut, Loop, OVERLAY 1–8, Audio Mixer…) stay English in both languages, like the app; the rest switches
/// with the 한 / EN button (remembered per device, default = app language).
extension WebRemote {
    static func remotePage() -> String {
        fill(remoteHTML, [
            "switcher": WL("스위처"), "audio": WL("오디오"), "titles": WL("타이틀"), "more": WL("더보기"),
            "input": WL("입력"), "lost": WL("연결 끊김 — 다시 연결하는 중…"),
            "tileHint": WL("탭: Preview · Cut: 바로 송출 · 1–8: 오버레이 넣기/빼기"),
            "bankEmpty": WL("입력 타일에서 이 오버레이에 넣을 입력을 먼저 지정하세요"),
            "help": WL("사용법"), "close": WL("닫기"), "cancel": WL("취소"),
            "h1": WL("입력 타일을 탭하면 그 입력이 PREVIEW로 갑니다."),
            "h2": WL("타일의 Cut은 그 입력을 바로 PROGRAM으로 보냅니다."),
            "h3": WL("타일의 1–8은 그 입력을 해당 오버레이에 넣고, 다시 누르면 뺍니다. 색이 켜진 번호가 지금 송출 중입니다."),
            "h4": WL("가운데 OVERLAY 1–8은 각 오버레이에 마지막으로 넣은 입력을 다시 넣거나 뺍니다."),
            "h5": WL("CUT은 PREVIEW를 바로 전환하고, Fade 같은 효과 버튼은 옆에서 고른 효과와 시간(ms)으로 전환합니다. T-Bar는 끝까지 밀면 전환이 끝납니다."),
            "h6": WL("⏮ 처음부터 · ▶/❚❚ 재생·일시정지 · Loop 반복 · 스피커 음소거. PROGRAM 아래 막대를 누르면 그 위치로 이동합니다."),
            "h7": WL("REC · STREAM · EXTERNAL은 시작하거나 멈출 때 확인 창이 뜹니다."),
            "h8": WL("타이틀 글자는 고친 뒤 '적용'을 눌러야 화면에 나갑니다."),
            "h9": WL("카메라맨 휴대폰은 /tally 주소를 여세요 (보기 전용, 비밀번호 없음)."),
            "h10": WL("화면 크기에 맞춰 배치가 바뀝니다. 휴대폰·아이패드 세로는 아래 탭으로 오디오·타이틀을 엽니다."),
            "streamOnQ": WL("송출을 시작할까요?"), "streamOnB": WL("설정된 송출 출력으로 바로 방송이 나갑니다."),
            "streamOnOK": WL("송출 시작"),
            "streamOffQ": WL("송출을 멈출까요?"), "streamOffB": WL("시청자에게 나가는 방송이 끊깁니다."),
            "streamOffOK": WL("송출 멈추기"),
            "recOnQ": WL("녹화를 시작할까요?"), "recOnB": WL("설정된 녹화 출력으로 파일을 기록합니다."),
            "recOnOK": WL("녹화 시작"),
            "recOffQ": WL("녹화를 멈출까요?"), "recOffB": WL("녹화 파일이 닫힙니다."), "recOffOK": WL("녹화 멈추기"),
            "extOnQ": WL("EXTERNAL 출력을 시작할까요?"), "extOnB": WL("NDI·DeckLink 출력이 켜집니다."),
            "extOnOK": WL("EXTERNAL 시작"),
            "extOffQ": WL("EXTERNAL 출력을 멈출까요?"), "extOffB": WL("NDI·DeckLink로 나가는 화면이 끊깁니다."),
            "extOffOK": WL("EXTERNAL 멈추기"),
            "running": WL("진행 중"), "noOut": WL("설정된 출력이 없습니다. HongMix 앱에서 먼저 추가하세요."),
            "pkts": WL("버린 패킷"), "srtOff": WL("연결 안 됨"),
            "noAudio": WL("오디오가 있는 입력이 없습니다"),
            "cd": WL("카운트다운"), "noCd": WL("카운트다운이 있는 타이틀이 없습니다"),
            "start": WL("시작"), "pause": WL("일시정지"), "stop": WL("정지"), "min": WL("분"),
            "noTitles": WL("타이틀 입력이 없습니다"), "noFields": WL("편집할 텍스트가 없습니다"),
            "apply": WL("적용"), "revert": WL("변경 취소"), "unsaved": WL("적용하지 않은 변경이 있습니다"),
            "applied": WL("적용했습니다"), "presets": WL("프리셋"), "noPresets": WL("저장된 프리셋 없음"),
            "anim": WL("애니메이션"), "ovl1": WL("오버레이 1 넣기 / 빼기"), "failed": WL("실패"),
            "noInputs": WL("입력이 없습니다"), "edit": WL("편집"),
            "prevSlide": WL("이전 슬라이드"), "nextSlide": WL("다음 슬라이드"),
            "prev": WL("이전"), "next": WL("다음"),
            "restart": WL("처음부터"), "play": WL("재생"), "mute": WL("음소거"), "noPreview": WL("Preview 입력 없음"),
            "qual": WL("화질"), "qSmooth": WL("부드럽게"), "qNormal": WL("보통"), "qSaver": WL("절약"),
            "h11": WL("화질: 부드럽게는 PREVIEW·PROGRAM을 초당 15장(화면 하나에 약 1~5 Mbps), 보통은 초당 8장(약 0.6~1.5 Mbps), 절약은 초당 2장(약 0.2 Mbps)으로 보냅니다. Wi-Fi가 약하거나 여러 대가 볼 때는 보통이나 절약을 고르세요."),
        ])
    }

    private static let remoteHTML = #"""
<!doctype html><html lang="__LANG__"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes"><meta name="theme-color" content="#0d0d10">
<title>HongMix Remote</title>
<style>
:root{--bg:#0d0d10;--panel:#16161a;--line:#2a2a31;--tx:#e8e8ea;--mute:#8b8b93;--btn:#26262c;--btnh:#31313a;--pvw:#2fbf4a;--pgm:#e5393b;--r:6px;--bh:30px}
body.touch{--bh:40px}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--tx);font:13px -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;-webkit-tap-highlight-color:transparent}
button,select,input{font:inherit;color:inherit}
button{background:var(--btn);border:1px solid var(--line);border-radius:var(--r);min-height:var(--bh);padding:0 8px;cursor:pointer;touch-action:manipulation;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
@media (hover:hover){button:hover{background:var(--btnh)}}
button:active{filter:brightness(1.35)}
button:disabled{opacity:.35;cursor:default}
select{background:var(--btn);border:1px solid var(--line);border-radius:var(--r);min-height:var(--bh);padding:0 6px;min-width:0}
input[type=text]{background:#111114;border:1px solid #3a3a42;border-radius:var(--r);padding:8px;width:100%;min-height:var(--bh);-webkit-user-select:text;user-select:text}
input[type=range]{width:100%;accent-color:#e8e8ea;height:var(--bh);margin:0;touch-action:none}
svg{width:14px;height:14px;fill:currentColor;vertical-align:-2px}
#top{display:flex;align-items:center;gap:10px;padding:6px 10px;padding-top:calc(6px + env(safe-area-inset-top));border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:5;flex-wrap:wrap}
.brand{font-weight:700;font-size:14px}.fmt{color:var(--mute)}
#stats{color:var(--mute);font-variant-numeric:tabular-nums;display:flex;gap:10px;flex-wrap:wrap;align-items:center}
#stats b{color:var(--tx);font-weight:600}
.g{color:#5c5}.y{color:#ec4}.bad{color:#f55;font-weight:600}
.sp{flex:1}
.seg{display:flex;border:1px solid var(--line);border-radius:var(--r);overflow:hidden}.seg button{border:0;border-radius:0;min-height:26px;background:transparent;color:var(--mute);padding:0 9px}.seg .on{background:var(--btnh);color:var(--tx)}
#qual{min-height:28px;font-size:12px;color:var(--tx)}
.ic{min-width:28px;padding:0;border-radius:50%;min-height:28px;height:28px}
#lost{display:none;background:#5a1a1a;padding:8px;text-align:center}
#main{display:grid;gap:8px;padding:8px}
.mon{background:var(--panel);border:2px solid;border-radius:8px;overflow:hidden;min-width:0;align-self:start}
#pvw{border-color:var(--pvw);grid-area:pvw}#pgm{border-color:var(--pgm);grid-area:pgm}
.mh{display:flex;gap:6px;align-items:center;padding:4px 8px;font-size:12px;white-space:nowrap;overflow:hidden;min-height:24px}
.mh b{letter-spacing:.06em}#pvw .mh b{color:var(--pvw)}#pgm .mh b{color:var(--pgm)}
.mh span{color:var(--mute);overflow:hidden;text-overflow:ellipsis}
.scr{position:relative;background:#000;aspect-ratio:16/9;overflow:hidden}
.scr img{position:absolute;inset:0;width:100%;height:100%;object-fit:contain}
.scr .none{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:#555}
#trp{display:flex;gap:4px;align-items:center;padding:3px 6px;min-height:calc(var(--bh) + 6px)}
#trp button{min-width:34px;padding:0}
#trp .sb{flex:1;min-width:0;font-weight:600;display:flex;gap:6px;align-items:center;justify-content:center;white-space:nowrap}#trp .sl{flex:0 0 auto;padding:0 6px;text-align:center;font-weight:700;font-variant-numeric:tabular-nums}
@media (max-width:520px){#trp .sb{gap:2px;font-size:13px}#trp .sl{padding:0 2px}}
#trp .sb.ic span{display:none}#trp .sb.ic svg{width:20px;height:20px}
#trp .bar{flex:1;height:var(--bh);display:flex;align-items:center;cursor:pointer;touch-action:none}
#trp .bar i{display:block;height:4px;background:#333;border-radius:2px;width:100%;position:relative}#trp .bar i b{position:absolute;left:0;top:0;bottom:0;background:var(--pgm);border-radius:2px}
.tm{font-variant-numeric:tabular-nums;color:var(--mute);font-size:12px;white-space:nowrap}
#mid{grid-area:mid;display:flex;flex-direction:column;gap:5px;min-width:0}
#midA,#midB{display:flex;flex-direction:column;gap:4px;min-width:0}
.cut{background:#f2f2f2!important;color:#111;font-weight:800;border-color:#f2f2f2;letter-spacing:.05em}
.qp{font-weight:700}
.trow{display:grid;grid-template-columns:minmax(0,1fr) 26px 64px;gap:2px}
.trow .go{font-weight:600}.trow.run .go{background:#2d5b8a;border-color:#3d79b8}
.trow .eff{width:26px;padding:0;color:transparent;text-align:center;background:var(--btn) no-repeat center/10px url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 6'%3E%3Cpath d='M0 0h10L5 6z' fill='%23aaa'/%3E%3C/svg%3E");-webkit-appearance:none;appearance:none}
.trow .eff option{color:#000}
.trow .dur{font-variant-numeric:tabular-nums;font-size:12px;padding:0 2px}
.ml{font-size:10px;font-weight:700;color:var(--mute);letter-spacing:.05em;margin-top:4px}
.bank{display:grid;grid-template-columns:repeat(4,1fr);gap:3px}
.bank button{padding:0;font-weight:700;color:#fff;border:0;opacity:.3;min-height:calc(var(--bh) - 4px)}
.bank button.saved{opacity:.75}.bank button.live{opacity:1;box-shadow:0 0 0 2px #fff inset}
.ftb.on{background:#000!important;border-color:var(--pgm);color:#f66}
#strip{grid-area:strip;display:none;grid-template-columns:1fr 1.2fr 1fr;gap:6px}
#strip button{font-weight:700}
#inputs{grid-area:inp;min-width:0}
.ih{display:flex;align-items:center;gap:8px;margin:2px 2px 6px;color:var(--mute);font-size:12px}
.ih b{color:var(--tx)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(var(--tile,176px),1fr));gap:6px}
.tile{background:var(--panel);border:2px solid var(--line);border-radius:7px;overflow:hidden;min-width:0}
.tile.pgm{border-color:var(--pgm)}.tile.pvw{border-color:var(--pvw)}
.th{display:flex;gap:5px;padding:3px 6px;font-weight:600;cursor:pointer;white-space:nowrap;overflow:hidden}
.th .no{color:var(--mute);flex:none}.th .nm{overflow:hidden;text-overflow:ellipsis}
.tile .scr{cursor:pointer}
.pb{position:absolute;left:0;right:0;bottom:0;height:3px;background:rgba(255,255,255,.15)}.pb b{display:block;height:100%;background:#5c5;width:0}
.tt{position:absolute;right:4px;bottom:6px;font-size:11px;background:rgba(0,0,0,.65);padding:0 4px;border-radius:3px;font-variant-numeric:tabular-nums}
.tr{display:flex;gap:2px;padding:2px 3px}.tr button{flex:1;min-width:0;padding:0 2px;min-height:calc(var(--bh) - 4px);font-size:12px}
.tr .on{background:#2d5b8a;border-color:#3d79b8}
.tr .ov{color:#fff;font-weight:700;border:0;opacity:.32}.tr .ov.saved{opacity:.6}.tr .ov.live{opacity:1;box-shadow:0 0 0 2px #fff inset}
.tr .muted{background:#5a1a1a;border-color:#a33;color:#f88}
.tr .gap{visibility:hidden}
.tr .slab{opacity:1!important;background:transparent;border-color:transparent;font-variant-numeric:tabular-nums;font-weight:600;flex:1.3}
#side{grid-area:side;background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:8px;min-width:0;align-self:start}
.sh{display:flex;gap:6px;align-items:center;margin-bottom:6px}
.sh .seg{flex:1}.sh .seg button{flex:1}
.ch{display:grid;grid-template-columns:minmax(0,1fr) 46px;gap:2px 8px;align-items:center;padding:6px 0;border-bottom:1px solid #222}
.nm2{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.nm2 small{color:var(--mute);margin-left:6px}
.mt{grid-column:1/3;height:5px;background:#222;border-radius:3px;overflow:hidden}.mt i{display:block;height:100%;width:0}
.mb{grid-row:1/3;grid-column:2;padding:0;font-weight:700}
.mb.muted{background:#5a1a1a;border-color:#a33;color:#f88}
.fl{color:var(--mute);font-size:12px;margin:8px 0 3px}
.dirty{border-color:#ec4!important}
.row{display:flex;gap:6px;margin:8px 0}.row>*{flex:1;min-width:0}
#cdT{font-size:38px;text-align:center;font-weight:700;font-variant-numeric:tabular-nums;margin:4px 0}
.empty{color:var(--mute);text-align:center;padding:14px}
.ok{background:#1d4d28!important;border-color:#2c8a43!important}
.danger{background:#7a1c1c!important;border-color:#c33!important;color:#fff}
.on2{border-color:var(--pgm)!important;background:#3a1515!important;color:#f99}
#bar{position:sticky;bottom:0;display:flex;gap:6px;align-items:center;padding:6px 8px;padding-bottom:calc(6px + env(safe-area-inset-bottom));background:var(--bg);border-top:1px solid var(--line);z-index:5}
#nav{display:none;gap:4px}#nav button{min-width:0}#nav .on{background:var(--btnh);border-color:#666}
#outs{display:flex;gap:6px;margin-left:auto}
#outs button{font-weight:700;min-width:72px}
#outs small{font-weight:500;margin-left:5px;font-variant-numeric:tabular-nums}
#tip{color:#666;font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.modal{position:fixed;inset:0;background:rgba(0,0,0,.6);display:none;align-items:center;justify-content:center;z-index:20;padding:16px}.modal.show{display:flex}
.box{background:#1e1e23;border:1px solid #3a3a42;border-radius:12px;padding:16px;max-width:440px;width:100%;max-height:85vh;overflow:auto}
.box h3{margin:0 0 6px;font-size:16px}.box p{margin:0 0 10px;color:#bbb;line-height:1.5}
.box ul{margin:0;padding-left:18px;color:#ccc;line-height:1.55}.box li{margin:4px 0}
#toast{position:fixed;left:50%;bottom:70px;transform:translateX(-50%);background:#333;color:#fff;padding:9px 16px;border-radius:20px;opacity:0;transition:opacity .2s;pointer-events:none;max-width:90vw;text-align:center;z-index:30}
/* desk */
body.L-desk #main{grid-template-columns:minmax(0,1fr) 172px minmax(0,1fr) minmax(250px,300px);grid-template-areas:"pvw mid pgm side" "inp inp inp side"}
/* tablet */
body.L-tab #main,body.L-phone #main{grid-template-columns:minmax(0,1fr) minmax(0,1fr);grid-template-areas:"pvw pgm" "mid mid" "strip strip" "inp inp" "side side"}
body.L-tab #mid{display:grid;grid-template-columns:minmax(0,1.3fr) minmax(0,1fr);gap:8px}
body.L-tab #midA{display:grid;grid-template-columns:1fr 1fr;gap:4px}
body.L-tab #midA .qp,body.L-tab #midA .cut{grid-column:auto}
body.L-tab{--tile:150px}
body.L-phone{--tile:140px}
body.L-phone .grid{grid-template-columns:minmax(0,1fr) minmax(0,1fr)}
body.L-phone .tr.r3{display:none}
body.L-phone #mid{display:none}
body.L-phone #strip{display:grid}
body.L-phone #tip{display:none}
body.L-phone #bar{flex-wrap:wrap}body.L-phone #nav,body.L-phone #outs{flex:1 1 100%;margin-left:0}body.L-phone #nav button,body.L-phone #outs button{flex:1;min-width:0;padding:0 4px}body.L-phone #tileHint{display:none}
body.L-tab #nav,body.L-phone #nav{display:flex}
body.L-tab:not(.v-sw) #pvw,body.L-tab:not(.v-sw) #pgm,body.L-tab:not(.v-sw) #mid,body.L-tab:not(.v-sw) #inputs{display:none}
body.L-phone:not(.v-sw) #pvw,body.L-phone:not(.v-sw) #pgm,body.L-phone:not(.v-sw) #strip,body.L-phone:not(.v-sw) #inputs{display:none}
body.L-tab.v-sw #side,body.L-phone.v-sw #side,body.L-phone.v-more #side{display:none}
body.L-phone.v-more #mid{display:flex}
body:not(.L-desk) .sh .seg{display:none}
body.L-phone .mh{font-size:11px;padding:2px 5px}
body.L-phone #stats .opt{display:none}
</style></head><body class="v-sw">
<div id="top"><span class="brand">HongMix</span><span class="fmt" id="fmt"></span><span id="stats"></span><span class="sp"></span>
<select id="qual" aria-label="quality"></select><div class="seg" id="lang"><button data-l="ko">한</button><button data-l="en">EN</button></div><button class="ic" id="helpB" aria-label="?">?</button></div>
<div id="lost"></div>
<div id="main">
<section class="mon" id="pvw"><div class="mh"><b>&#9679; PREVIEW</b><span id="pvwN"></span></div><div class="scr"><img id="pvwI" alt=""><div class="none" id="pvwX"></div></div></section>
<section id="mid"><div id="midA"><button class="qp" id="qp">Quick Play</button><button class="cut" id="cut">CUT</button><div class="trow" data-s="1"></div><div class="trow" data-s="2"></div><div class="trow" data-s="3"></div><div class="trow" data-s="4"></div></div>
<div id="midB"><div class="ml">OVERLAY 1&#8211;8</div><div class="bank" id="bank"></div><div class="ml">T-BAR</div><input type="range" id="tbar" min="0" max="255" step="1" value="0"><button class="ftb" id="ftb">FTB</button></div></section>
<section class="mon" id="pgm"><div class="mh"><b>&#9679; PROGRAM</b><span id="pgmN"></span></div><div class="scr"><img id="pgmI" alt=""></div><div id="trp"></div></section>
<div id="strip"><button class="cut" id="cut2">CUT</button><button id="go1"></button><button class="ftb" id="ftb2">FTB</button></div>
<section id="inputs"><div class="ih"><b id="inT"></b><span id="inC"></span><span class="sp"></span><span id="tileHint"></span></div><div class="grid" id="grid"></div></section>
<aside id="side"><div class="sh"><div class="seg" id="sideSeg"><button data-p="au">Audio Mixer</button><button data-p="ti" id="segTi"></button></div></div>
<div id="pAu"><div id="chs"></div><div class="fl" id="cdL"></div><select id="cdSel"></select><div id="cdT">--:--</div>
<div class="row" id="cdR1"><button id="cdStart"></button><button id="cdPause"></button><button id="cdStop"></button></div><div class="row" id="cdR2"><button id="cdMinus"></button><button id="cdPlus"></button></div><p class="empty" id="cdNone"></p></div>
<div id="pTi"><select id="tSel"></select><p class="empty" id="tNone"></p><div id="tBody"><div id="fields"></div><p class="fl" id="unsaved" style="color:#ec4"></p>
<div class="row"><button class="ok" id="apply"></button><button id="revert"></button></div><div class="fl" id="preL"></div>
<div class="row"><button id="prev">&#9664;</button><button id="preN" style="flex:3"></button><button id="next">&#9654;</button></div><div class="fl" id="animL"></div>
<div class="row"><button id="tin">IN</button><button id="tout">OUT</button></div><div class="row"><button id="tovl" style="font-weight:700"></button></div></div></div>
</aside>
</div>
<div id="bar"><div id="nav"><button data-v="sw"></button><button data-v="au"></button><button data-v="ti"></button><button data-v="more" id="navMore"></button></div><span id="tip"></span>
<div id="outs"><button id="oRec" data-o="record">REC<small></small></button><button id="oStream" data-o="stream">STREAM<small></small></button><button id="oExt" data-o="external">EXTERNAL<small></small></button></div></div>
<div class="modal" id="cf"><div class="box"><h3 id="cfQ"></h3><p id="cfB"></p><div class="row"><button id="cfNo"></button><button id="cfOk"></button></div></div></div>
<div class="modal" id="hp"><div class="box"><h3 id="hpT"></h3><ul id="hpL"></ul><div class="row"><button id="hpC"></button></div></div></div>
<div id="toast"></div>
<script>
const T=__T__;
const $=id=>document.getElementById(id);
function ls(k,v){try{if(v===undefined)return localStorage.getItem(k);localStorage.setItem(k,v)}catch(e){return null}}
let lang=ls('hmLang')||document.documentElement.lang;
const t=k=>T[k]?T[k][lang=='en'?1:0]:k;
const OC=['#e0661a','#297ae0','#9957d1','#149eb8','#d14d8c','#b38c14','#1f9475','#d13d40'];
const FX=['Fade','Merge','Wipe','Slide','Fly','CrossZoom','Zoom','FadeToBlack'];
const DUR=[0,250,500,750,1000,1500,2000,3000];
const IC={re:'<svg viewBox="0 0 16 16"><path d="M3 3h2v10H3zM13 3v10L5.5 8z"/></svg>',play:'<svg viewBox="0 0 16 16"><path d="M4 2.5l10 5.5-10 5.5z"/></svg>',
 pause:'<svg viewBox="0 0 16 16"><path d="M4 3h3v10H4zM9 3h3v10H9z"/></svg>',prev:'<svg viewBox="0 0 16 16"><path d="M10.5 2.5L5 8l5.5 5.5" stroke="currentColor" stroke-width="2.2" fill="none"/></svg>',next:'<svg viewBox="0 0 16 16"><path d="M5.5 2.5L11 8l-5.5 5.5" stroke="currentColor" stroke-width="2.2" fill="none"/></svg>',spk:'<svg viewBox="0 0 16 16"><path d="M2 6h3l4-3v10L5 10H2z"/><path d="M11 5.2a4 4 0 0 1 0 5.6M12.8 3.5a6.5 6.5 0 0 1 0 9" stroke="currentColor" stroke-width="1.3" fill="none"/></svg>',
 off:'<svg viewBox="0 0 16 16"><path d="M2 6h3l4-3v10L5 10H2z"/><path d="M11 6l4 4M15 6l-4 4" stroke="currentColor" stroke-width="1.4"/></svg>'};
const QP={smooth:{fps:15,w:{desk:854,tab:640,phone:480},tiles:2000},normal:{fps:8,w:{desk:640,tab:480,phone:400},tiles:3000},saver:{fps:2,w:{desk:480,tab:400,phone:320},tiles:8000}};
let qual=ls('hmQual')||'normal';if(!QP[qual])qual='normal';
let S=null,L='',view=ls('hmView')||'sw',sideP=ls('hmSide')||'au',tSel=+(ls('hmTitle')||0),cdSel=+(ls('hmCd')||0),dirty=false,touching=null,timer=null,busy=false,again=false,failN=0,gridSig='',chSig='',fieldSig='',thumbAt=0;
if(!['sw','au','ti','more'].includes(view))view='sw';if(!['au','ti'].includes(sideP))sideP='au';
if(matchMedia('(pointer:coarse)').matches)document.body.classList.add('touch');
function toast(x){const el=$('toast');el.textContent=x;el.style.opacity=1;clearTimeout(el._t);el._t=setTimeout(()=>el.style.opacity=0,2200)}
// every request gives up after 3 s, so a Wi-Fi drop shows 'connection lost' instead of freezing on old state
function tfetch(u){const c=new AbortController(),tm=setTimeout(()=>c.abort(),3000);return fetch(u,{cache:'no-store',signal:c.signal}).finally(()=>clearTimeout(tm))}
function api(fn,p,quiet){let u='/api/?Function='+encodeURIComponent(fn);for(const k in(p||{}))u+='&'+k+'='+encodeURIComponent(p[k]);
 return tfetch(u).then(r=>{if(!r.ok)return r.text().then(x=>{toast(t('failed')+': '+x);throw 0})}).catch(e=>{if(e!==0)toast(t('lost'));throw e}).finally(()=>{if(!quiet)poll()})}
const run=(fn,p,q)=>api(fn,p,q).catch(()=>{});
function every(){return L=='desk'||view=='au'?400:700}
function poll(){if(busy){again=true;return}busy=true;clearTimeout(timer);
 tfetch('/remote.json').then(r=>{if(!r.ok)throw 0;return r.json()}).then(s=>{S=s;failN=0;$('lost').style.display='none';render()})
 .catch(()=>{if(++failN>=2){$('lost').style.display='block';$('lost').textContent=t('lost')}})
 .finally(()=>{busy=false;if(again){again=false;poll()}else timer=setTimeout(poll,every())})}
function fmt(s){s=Math.max(0,Math.floor(s||0));const h=Math.floor(s/3600),m=Math.floor(s/60)%60,x=s%60;return(h?h+':'+String(m).padStart(2,'0'):m)+':'+String(x).padStart(2,'0')}
function inp(n){return S&&S.inputs.find(i=>i.n==n)}
function el(tag,cls,txt){const e=document.createElement(tag);if(cls)e.className=cls;if(txt!=null)e.textContent=txt;return e}
function throttle(f,ms){let last=0,tm=null,a=null;return v=>{a=v;const now=Date.now();if(now-last>=ms){last=now;f(a)}else{clearTimeout(tm);tm=setTimeout(()=>{last=Date.now();f(a)},ms-(now-last))}}}
function confirmBox(q,b,ok,danger,fn){$('cfQ').textContent=q;$('cfB').textContent=b;$('cfNo').textContent=t('cancel');$('cfOk').textContent=ok;$('cfOk').className=danger?'danger':'ok';
 $('cf').classList.add('show');$('cfOk').onclick=()=>{$('cf').classList.remove('show');fn()};$('cfNo').onclick=()=>$('cf').classList.remove('show')}
$('cf').onclick=e=>{if(e.target.id=='cf')$('cf').classList.remove('show')};$('hp').onclick=e=>{if(e.target.id=='hp')$('hp').classList.remove('show')};
// ---- layout
function layout(){const w=innerWidth,n=w>=1100?'desk':w>=700?'tab':'phone';if(n!=L){L=n;document.body.classList.remove('L-desk','L-tab','L-phone');document.body.classList.add('L-'+n);if(L!='phone'&&view=='more')view='sw';thumbAt=0}
 ['sw','au','ti','more'].forEach(v=>document.body.classList.toggle('v-'+v,v==view));
 const p=L=='desk'?sideP:(view=='ti'?'ti':'au');$('pAu').style.display=p=='au'?'block':'none';$('pTi').style.display=p=='ti'?'block':'none';
 document.querySelectorAll('#sideSeg button').forEach(b=>b.classList.toggle('on',b.dataset.p==p));
 document.querySelectorAll('#nav button').forEach(b=>b.classList.toggle('on',b.dataset.v==view));$('navMore').style.display=L=='phone'?'':'none'}
function setView(v){view=v;ls('hmView',v);layout();streams();if(S)render();poll()}
function setSide(p){sideP=p;ls('hmSide',p);layout();if(S)render()}
document.querySelectorAll('#nav button').forEach(b=>b.onclick=()=>setView(b.dataset.v));
document.querySelectorAll('#sideSeg button').forEach(b=>b.onclick=()=>setSide(b.dataset.p));
addEventListener('resize',()=>{layout();streams();if(S)render()});
// ---- texts
function texts(){document.documentElement.lang=lang;document.querySelectorAll('#lang button').forEach(b=>b.classList.toggle('on',b.dataset.l==lang));
 document.querySelectorAll('#nav button').forEach(b=>b.textContent=t({sw:'switcher',au:'audio',ti:'titles',more:'more'}[b.dataset.v]));
 $('segTi').textContent=t('titles');$('inT').textContent=t('input');$('tileHint').textContent=t('tileHint');$('tip').textContent='Tally: /tally';
 $('cdL').textContent=t('cd');$('cdStart').textContent=t('start');$('cdPause').textContent=t('pause');$('cdStop').textContent=t('stop');
 $('cdMinus').textContent='-1 '+t('min');$('cdPlus').textContent='+1 '+t('min');$('cdNone').textContent=t('noCd');
 $('apply').textContent=t('apply');$('revert').textContent=t('revert');$('preL').textContent=t('presets');$('animL').textContent=t('anim');$('tovl').textContent=t('ovl1');
 $('tNone').textContent=t('noTitles');$('unsaved').textContent=t('unsaved');$('pvwX').textContent=t('noPreview');
 const qs=$('qual');qs.innerHTML='';[['smooth','qSmooth',15],['normal','qNormal',8],['saver','qSaver',2]].forEach(([v,k,f])=>qs.add(new Option(t('qual')+': '+t(k)+' · '+f+' fps',v)));qs.value=qual;
 $('hpT').textContent=t('help');$('hpC').textContent=t('close');const ul=$('hpL');ul.innerHTML='';for(let i=1;i<=11;i++)ul.appendChild(el('li','',t('h'+i)));
 gridSig='';chSig='';fieldSig='';if(S)render()}
$('qual').onchange=e=>{qual=e.target.value;ls('hmQual',qual);thumbAt=0;streams()};
document.querySelectorAll('#lang button').forEach(b=>b.onclick=()=>{lang=b.dataset.l;ls('hmLang',lang);texts()});
$('helpB').onclick=()=>$('hp').classList.add('show');$('hpC').onclick=()=>$('hp').classList.remove('show');
// ---- render
function render(){top_();renderOuts();
 if(L=='desk'||view=='sw'){renderMon();renderInputs()}
 if(L=='desk'||view=='sw'||view=='more')renderMid();
 if(L=='desk'?sideP=='au':view=='au')renderAu();
 if(L=='desk'?sideP=='ti':view=='ti')renderTi()}
function top_(){$('fmt').textContent=S.format;const st=$('stats');st.innerHTML='';
 const add=(k,v,c,opt)=>{const s=el('span',opt?'opt':'');if(k)s.appendChild(document.createTextNode(k+' '));const b=el('b',c||'',v);s.appendChild(b);st.appendChild(s)};
 add('FPS',S.fps.toFixed(2),'',true);add('Render',S.renderMs.toFixed(1)+' ms','',true);add('Max',S.renderMax.toFixed(1)+' ms','',true);add('Drop',String(S.dropped),S.dropped>0?'y':'');
 for(const l of S.srt){const c=!l.connected||l.drops>0?'bad':l.loss>1?'y':'g';add('',('SRT '+l.n+' ')+(l.connected?Math.round(l.rtt)+' ms · '+l.loss.toFixed(1)+'%'+(l.drops>0?' · '+t('pkts')+' '+l.drops:''):t('srtOff')),c)}}
function renderOuts(){[['oRec','record'],['oStream','stream'],['oExt','external']].forEach(([id,k])=>{const b=$(id),o=S[k];b.classList.toggle('on2',o.on);b.querySelector('small').textContent=o.on?fmt(o.sec):''})}
// live PREVIEW / PROGRAM: one MJPEG stream per monitor, closed while not visible (saves Wi-Fi and HongMix work)
function setStream(img,src,on){const p=QP[qual],u=on?'/stream.mjpg?source='+src+'&fps='+p.fps+'&w='+p.w[L||'desk']:'';
 if(img.dataset.u===u)return;img.dataset.u=u;if(u){img.style.visibility='hidden';img.onload=()=>{img.style.visibility='visible'};img.src=u}else{img.removeAttribute('src');img.style.visibility='hidden'}}
function streams(){const vis=(L=='desk'||view=='sw')&&!document.hidden;setStream($('pgmI'),'program',vis);setStream($('pvwI'),'preview',vis&&!!(S&&S.preview))}
['pgmI','pvwI'].forEach(id=>{const im=$(id);im.onerror=()=>{const u=im.dataset.u;im.dataset.u='';if(u)setTimeout(streams,2000)}});
function renderMon(){const a=inp(S.active),p=inp(S.preview);$('pgmN').textContent=a?a.n+' '+a.title:'';$('pvwN').textContent=p?p.n+' '+p.title:'';$('pvwX').style.display=p?'none':'flex';
 streams();
 const tp=$('trp'),mode=a&&a.slides!==undefined?'s':a&&a.media?'m':'';
 if(tp.dataset.b!==mode){tp.dataset.b=mode;tp.innerHTML='';
  if(mode=='m'){tp.innerHTML='<button data-a="re">'+IC.re+'</button><button data-a="pp"></button><span class="bar"><i><b></b></i></span><span class="tm"></span>';
   tp.querySelector('[data-a=re]').onclick=()=>run('Restart',{Input:S.active});tp.querySelector('[data-a=pp]').onclick=()=>{const x=inp(S.active);run(x&&x.playing?'Pause':'Play',{Input:S.active})};
   tp.querySelector('.bar').onclick=e=>{const x=inp(S.active);if(!x||!x.dur)return;const r=e.currentTarget.getBoundingClientRect();run('SetPosition',{Input:S.active,Value:Math.round(Math.max(0,Math.min(1,(e.clientX-r.left)/r.width))*x.dur*1000)})}}
  if(mode=='s'){tp.innerHTML='<button data-a="sp" class="sb">'+IC.prev+'<span></span></button><span class="sl"></span><button data-a="sn" class="sb"><span></span>'+IC.next+'</button>';
   tp.querySelector('[data-a=sp]').onclick=()=>run('PreviousPicture',{Input:S.active});tp.querySelector('[data-a=sn]').onclick=()=>run('NextPicture',{Input:S.active})}}
 if(mode=='m'){tp.style.visibility='visible';tp.querySelector('[data-a=pp]').innerHTML=a.playing?IC.pause:IC.play;tp.querySelector('.bar b').style.width=(a.dur?Math.min(100,a.pos/a.dur*100):0)+'%';tp.querySelector('.tm').textContent=fmt(a.pos)+' / '+fmt(a.dur)}
 else if(mode=='s'){tp.style.visibility='visible';tp.querySelector('.sl').textContent=a.slides?a.slide+' / '+a.slides:'– / –';
  tp.querySelector('[data-a=sp] span').textContent=t('prev');tp.querySelector('[data-a=sn] span').textContent=t('next');
  const sb=[...tp.querySelectorAll('.sb')];sb.forEach(b=>b.classList.remove('ic'));const tight=sb.some(b=>b.querySelector('span').offsetWidth+32>b.clientWidth);sb.forEach(b=>b.classList.toggle('ic',tight))}
 else tp.style.visibility='hidden'}
function renderMid(){document.querySelectorAll('.trow').forEach(r=>{const s=+r.dataset.s,tr=S.trans[s-1];if(!tr){r.style.display='none';return}
  if(!r.children.length){const go=el('button','go'),ef=el('select','eff'),du=el('select','dur');FX.forEach(v=>ef.add(new Option(v,v)));ef.setAttribute('aria-label','effect');
   go.onclick=()=>run('Transition'+s);ef.onchange=()=>run('SetTransitionEffect'+s,{Value:ef.value});du.onchange=()=>run('SetTransitionDuration'+s,{Value:du.value});r.append(go,ef,du)}
  const[go,ef,du]=r.children;go.textContent=tr.effect=='FadeToBlack'?'FTB fade':tr.effect;if(document.activeElement!==ef)ef.value=tr.effect;
  const ds=DUR.includes(tr.duration)?DUR:DUR.concat([tr.duration]).sort((a,b)=>a-b);if(du.options.length!=ds.length&&document.activeElement!==du){du.innerHTML='';ds.forEach(v=>du.add(new Option(String(v),v)))}
  if(document.activeElement!==du)du.value=tr.duration});
 const bk=$('bank');if(!bk.children.length)for(let c=1;c<=8;c++){const b=el('button','',String(c));b.style.background=OC[c-1];b.onclick=()=>{const o=S.bank[c-1];if(o.on)run('OverlayInput'+c+'Out');else if(o.n)run('OverlayInput'+c+'Last');else toast(t('bankEmpty'))};bk.appendChild(b)}
 [...bk.children].forEach((b,i)=>{const o=S.bank[i];b.classList.toggle('live',o.on);b.classList.toggle('saved',!o.on&&o.n>0);const x=inp(o.n);b.title=o.n?'Overlay '+(i+1)+' · '+o.n+' '+(x?x.title:''):t('bankEmpty')});
 $('ftb').classList.toggle('on',S.ftb);$('ftb2').classList.toggle('on',S.ftb);$('go1').textContent=S.trans[0].effect+' '+S.trans[0].duration;
 if(touching!==$('tbar'))$('tbar').value=Math.round(S.tbar*255)}
$('qp').onclick=()=>{if(S&&S.preview)run('QuickPlay',{Input:S.preview})};$('cut').onclick=$('cut2').onclick=()=>run('Cut');$('ftb').onclick=$('ftb2').onclick=()=>run('FadeToBlack');$('go1').onclick=()=>run('Transition1');
let fLast=-1;const sendF=v=>{v=+v;if(v===fLast)return;fLast=v;run('SetFader',{Value:v},true)};const fader=throttle(sendF,60),tb=$('tbar');
tb.onpointerdown=()=>{touching=tb;fLast=-1};tb.oninput=()=>fader(+tb.value>=250?255:tb.value);
tb.onchange=()=>{touching=null;if(+tb.value>=250){sendF(255);tb.value=0}setTimeout(poll,150)};tb.onpointerup=tb.onpointercancel=()=>setTimeout(()=>{if(touching===tb)touching=null},60);
// ---- tiles
function tile(i){const d=el('div','tile');d.dataset.n=i.n;const h=el('div','th');h.append(el('span','no',String(i.n)),el('span','nm',i.title));
 const sc=el('div','scr');const im=el('img');im.alt='';im.draggable=false;im.onerror=()=>im.style.visibility='hidden';im.onload=()=>im.style.visibility='visible';sc.appendChild(im);
 if(i.media){const pb=el('div','pb');pb.appendChild(el('b'));sc.append(pb,el('span','tt'))}
 const r1=el('div','tr r1');
 if(i.fields){r1.append(btn('cut','Cut'),btn('edit',t('edit')))}
 else if(i.slides!==undefined){const sl=btn('slab','');sl.disabled=true;sl.classList.add('slab');r1.append(btnI('sp',IC.prev,false,t('prevSlide')),sl,btnI('sn',IC.next,false,t('nextSlide')),btn('cut','Cut'))}
 else{r1.append(btnI('re',IC.re,!i.media,t('restart')),btnI('pp',IC.play,!i.media,t('play')),btn('cut','Cut'),btn('loop','Loop',!i.media))}
 const r2=el('div','tr r2'),r3=el('div','tr r3');r2.appendChild(btnI('mute',IC.spk,!i.audio,t('mute')));r3.appendChild(el('button','gap'));
 for(let c=1;c<=8;c++){const b=btn('ov',String(c));b.dataset.c=c;b.classList.add('ov');b.style.background=OC[c-1];(c<=4?r2:r3).appendChild(b)}
 d.append(h,sc,r1,r2,r3);return d}
function btn(a,txt,dis){const b=el('button','',txt);b.dataset.a=a;if(dis)b.disabled=true;return b}
function btnI(a,svg,dis,lab){const b=btn(a,'',dis);b.innerHTML=svg;b.setAttribute('aria-label',lab);b.title=lab;return b}
$('grid').addEventListener('click',e=>{const d=e.target.closest('.tile');if(!d||!S)return;const n=+d.dataset.n,i=inp(n);if(!i)return;const b=e.target.closest('button');
 if(!b){if(e.target.closest('.th,.scr'))run('PreviewInput',{Input:n});return}
 switch(b.dataset.a){case'cut':run('CutDirect',{Input:n});break;case're':run('Restart',{Input:n});break;case'pp':run(i.playing?'Pause':'Play',{Input:n});break;
  case'loop':run(i.loop?'LoopOff':'LoopOn',{Input:n});break;case'sp':run('PreviousPicture',{Input:n});break;case'sn':run('NextPicture',{Input:n});break;case'mute':run(i.muted?'AudioOn':'AudioOff',{Input:n});break;
  case'edit':tSel=n;ls('hmTitle',n);fieldSig='';dirty=false;if(L=='desk')setSide('ti');else setView('ti');break;
  case'ov':{const c=+b.dataset.c;run(S.overlays[c-1]==n?'OverlayInput'+c+'Out':'OverlayInput'+c+'In',{Input:n});break}}});
function renderInputs(){const g=$('grid'),sig=S.inputs.map(i=>[i.n,i.title,!!i.media,!!i.fields,i.audio,i.slides!==undefined].join('\u0001')).join('\u0002')+lang;
 $('inC').textContent=String(S.inputs.length);
 if(sig!=gridSig){gridSig=sig;g.innerHTML='';thumbAt=0;if(!S.inputs.length)g.appendChild(el('p','empty',t('noInputs')));S.inputs.forEach(i=>g.appendChild(tile(i)))}
 g.querySelectorAll('.tile').forEach(d=>{const n=+d.dataset.n,i=inp(n);if(!i)return;const pg=n==S.active,pv=n==S.preview&&!pg;
  d.classList.toggle('pgm',pg);d.classList.toggle('pvw',pv);const live=S.overlays.indexOf(n);d.style.borderColor=!pg&&!pv&&live>=0?OC[live]:'';
  if(i.media){const pp=d.querySelector('[data-a=pp]');if(pp){pp.innerHTML=i.playing?IC.pause:IC.play;pp.classList.toggle('on',i.playing)}const lo=d.querySelector('[data-a=loop]');if(lo)lo.classList.toggle('on',i.loop);
   const pb=d.querySelector('.pb b');if(pb)pb.style.width=(i.dur?Math.min(100,i.pos/i.dur*100):0)+'%';const tt=d.querySelector('.tt');if(tt)tt.textContent=i.dur?fmt(i.dur-i.pos):''}
  const sl=d.querySelector('[data-a=slab]');if(sl)sl.textContent=i.slides?i.slide+' / '+i.slides:'– / –';
  const m=d.querySelector('[data-a=mute]');if(m&&!m.disabled){m.innerHTML=i.muted?IC.off:IC.spk;m.classList.toggle('muted',i.muted)}
  d.querySelectorAll('.ov').forEach(b=>{const c=+b.dataset.c;b.classList.toggle('live',S.overlays[c-1]==n);b.classList.toggle('saved',S.overlays[c-1]!=n&&S.bank[c-1].n==n)})});
 if(Date.now()-thumbAt>QP[qual].tiles&&!document.hidden&&!thumbQ.length){thumbAt=Date.now();thumbQ=[...g.querySelectorAll('.tile img')];thumbNext();thumbNext()}}
let thumbQ=[];function thumbNext(){const im=thumbQ.shift();if(!im)return;const n=new Image(),done=()=>{clearTimeout(tm);thumbNext()},tm=setTimeout(done,3000);
 n.onload=()=>{im.src=n.src;done()};n.onerror=()=>{im.style.visibility='hidden';done()};n.src='/thumb?input='+im.closest('.tile').dataset.n+'&width=320&t='+Date.now()}
// ---- outputs
function outBtn(id,k,fn,nm){$(id).onclick=()=>{if(!S)return;const o=S[k];if(!o.has&&!o.on){toast(t('noOut'));return}
 if(o.on)confirmBox(t(nm+'OffQ'),t(nm+'OffB')+' ('+t('running')+' '+fmt(o.sec)+')',t(nm+'OffOK'),true,()=>run('Stop'+fn));
 else confirmBox(t(nm+'OnQ'),t(nm+'OnB'),t(nm+'OnOK'),false,()=>run('Start'+fn))}}
outBtn('oStream','stream','Streaming','stream');outBtn('oRec','record','Recording','rec');outBtn('oExt','external','External','ext');
// ---- audio
function meter(m,a,b){const v=Math.max(a||0,b||0),db=v>0?20*Math.log10(v):-90,p=Math.max(0,Math.min(100,(db+60)/60*100));m.style.width=p+'%';m.style.background=db>-3?'#e33':db>-9?'#ec4':'#2c2'}
function chRow(key,name,isM){const r=el('div','ch');r.dataset.k=key;const nm=el('div','nm2');nm.append(document.createTextNode(name),el('small'));
 const mb=el('button','mb','M');mb.setAttribute('aria-label',t('mute'));const rg=el('input');rg.type='range';rg.min=0;rg.max=100;rg.step=1;const mt=el('div','mt');mt.appendChild(el('i'));
 const set=throttle(v=>isM?run('SetMasterVolume',{Value:v},true):run('SetVolume',{Input:key,Value:v},true),80);
 rg.onpointerdown=()=>touching=rg;rg.oninput=()=>{nm.lastChild.textContent=rg.value;set(rg.value)};rg.onchange=()=>{touching=null};rg.onpointerup=rg.onpointercancel=()=>setTimeout(()=>{if(touching===rg)touching=null},60);
 mb.onclick=()=>{if(isM)run(S.master.muted?'MasterAudioOn':'MasterAudioOff');else{const i=inp(key);run(i&&i.muted?'AudioOn':'AudioOff',{Input:key})}};r.append(nm,mb,rg,mt);return r}
function renderAu(){const box=$('chs'),list=S.inputs.filter(i=>i.audio),sig=list.map(i=>i.n+'\u0001'+i.title).join('\u0002')+lang;
 if(sig!=chSig){chSig=sig;box.innerHTML='';box.appendChild(chRow('M','Master',true));list.forEach(i=>box.appendChild(chRow(i.n,i.n+' '+i.title,false)));if(!list.length)box.appendChild(el('p','empty',t('noAudio')))}
 box.querySelectorAll('.ch').forEach(r=>{const m=r.dataset.k=='M',i=m?S.master:inp(+r.dataset.k);if(!i)return;const rg=r.querySelector('input');
  if(touching!==rg){rg.value=i.volume;r.querySelector('small').textContent=i.volume}r.querySelector('.mb').classList.toggle('muted',i.muted);meter(r.querySelector('.mt i'),i.muted?0:i.m1,i.muted?0:i.m2)});
 const cds=S.inputs.filter(i=>i.cd!==undefined),sel=$('cdSel'),has=cds.length>0;
 ['cdSel','cdT','cdR1','cdR2'].forEach(id=>$(id).style.display=has?'':'none');$('cdNone').style.display=has?'none':'block';if(!has)return;
 if(!cds.find(i=>i.n==cdSel))cdSel=cds[0].n;const s2=cds.map(i=>i.n+i.title).join();if(sel.dataset.sig!=s2){sel.dataset.sig=s2;sel.innerHTML='';cds.forEach(i=>sel.add(new Option(i.n+' '+i.title,i.n)))}
 if(document.activeElement!==sel)sel.value=cdSel;const c=inp(cdSel);$('cdT').textContent=fmt(Math.ceil(c.cd));$('cdT').style.color=c.cdRun?'#5c5':''}
$('cdSel').onchange=e=>{cdSel=+e.target.value;ls('hmCd',cdSel);render()};
$('cdStart').onclick=()=>run('StartCountdown',{Input:cdSel});$('cdPause').onclick=()=>run('PauseCountdown',{Input:cdSel});$('cdStop').onclick=()=>run('StopCountdown',{Input:cdSel});
$('cdMinus').onclick=()=>run('AdjustCountdown',{Input:cdSel,Value:-60});$('cdPlus').onclick=()=>run('AdjustCountdown',{Input:cdSel,Value:60});
// ---- titles
function setDirty(v){dirty=v;$('unsaved').style.display=v?'block':'none'}
function renderTi(){const ts=S.inputs.filter(i=>i.fields),sel=$('tSel'),has=ts.length>0;sel.style.display=has?'':'none';$('tBody').style.display=has?'block':'none';$('tNone').style.display=has?'none':'block';if(!has)return;
 if(!ts.find(i=>i.n==tSel)){tSel=ts[0].n;setDirty(false)}const s2=ts.map(i=>i.n+i.title).join();if(sel.dataset.sig!=s2){sel.dataset.sig=s2;sel.innerHTML='';ts.forEach(i=>sel.add(new Option(i.n+' '+i.title,i.n)))}
 if(document.activeElement!==sel)sel.value=tSel;const ti=inp(tSel),box=$('fields'),fs=tSel+':'+ti.fields.map(f=>f.name).join('\u0001')+lang;
 if(fs!=fieldSig){fieldSig=fs;box.innerHTML='';setDirty(false);if(!ti.fields.length)box.appendChild(el('p','empty',t('noFields')));
  ti.fields.forEach(f=>{const e=el('input');e.type='text';e.dataset.name=f.name;e.oninput=()=>{e.classList.toggle('dirty',e.value!==e.dataset.orig);setDirty([...box.querySelectorAll('input')].some(x=>x.value!==x.dataset.orig))};
   box.append(el('div','fl',f.name.replace(/\.Text$/,'')),e)})}
 box.querySelectorAll('input').forEach(e=>{const f=ti.fields.find(x=>x.name==e.dataset.name);if(!f)return;if(!dirty&&document.activeElement!==e){e.value=f.text;e.classList.remove('dirty')}e.dataset.orig=f.text});
 if(!dirty)setDirty(false);$('preN').textContent=ti.presets?(ti.preset>=0?(ti.preset+1):'-')+' / '+ti.presets:t('noPresets');$('tovl').classList.toggle('on2',S.overlays[0]==tSel)}
$('tSel').onchange=e=>{tSel=+e.target.value;ls('hmTitle',tSel);fieldSig='';setDirty(false);render()};
$('apply').onclick=async()=>{const ch=[...$('fields').querySelectorAll('input')].filter(e=>e.value!==e.dataset.orig);
 try{for(const e of ch){await api('SetText',{Input:tSel,SelectedName:e.dataset.name,Value:e.value},true);e.dataset.orig=e.value;e.classList.remove('dirty')}setDirty(false);if(ch.length)toast(t('applied'))}catch(e){}poll()};
$('revert').onclick=()=>{$('fields').querySelectorAll('input').forEach(e=>{e.value=e.dataset.orig;e.classList.remove('dirty')});setDirty(false)};
$('prev').onclick=()=>{setDirty(false);run('PreviousTitlePreset',{Input:tSel})};$('next').onclick=()=>{setDirty(false);run('NextTitlePreset',{Input:tSel})};
$('tin').onclick=()=>run('TitleBeginAnimation',{Input:tSel,Value:'TransitionIn'});$('tout').onclick=()=>run('TitleBeginAnimation',{Input:tSel,Value:'TransitionOut'});
$('tovl').onclick=()=>{if(S.overlays[0]==tSel)run('OverlayInput1Out');else run('OverlayInput1In',{Input:tSel})};
document.addEventListener('visibilitychange',()=>{streams();if(!document.hidden)poll()});
document.addEventListener('keydown',e=>{if(e.key=='Escape'){$('cf').classList.remove('show');$('hp').classList.remove('show')}});
setDirty(false);layout();texts();poll();
</script></body></html>
"""#
}
