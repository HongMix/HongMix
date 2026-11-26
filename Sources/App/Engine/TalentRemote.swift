import Foundation

/// Moderator remote for Talent Cue: `/talent?key=TOKEN` (page), `/talent.json?key=` (state, polled),
/// `/talent/cmd?key=&a=…` (actions, TalentCue.perform). The key replaces the HTTP password for these paths
/// only, so a moderator gets the Talent Cue and nothing else of the switcher.
enum TalentRemote {
    static func isTalentPath(_ path: String) -> Bool { TalentAccess.isTalentPath(path) }

    /// Main thread. nil = not a Talent Cue path.
    static func route(_ path: String, _ q: [String: String]) -> (String, String, String)? {
        guard isTalentPath(path) else { return nil }
        let cue = TalentCue.shared
        guard TalentAccess.keyMatches(q["key"], token: cue.token) else {
            return ("403 Forbidden", "text/plain; charset=utf-8", "invalid or expired link")
        }
        switch path {
        case "/talent", "/talent/": return ("200 OK", "text/html; charset=utf-8", page())
        case "/talent.json": return ("200 OK", "application/json; charset=utf-8", cue.stateJSON())
        case "/talent/cmd":
            if let err = cue.perform(q) { return ("400 Bad Request", "text/plain; charset=utf-8", err) }
            return ("200 OK", "application/json; charset=utf-8", cue.stateJSON())
        default: return ("404 Not Found", "text/plain", "not found")
        }
    }

    private static func page() -> String {
        let WL = WebRemote.WL
        return WebRemote.fill(html, [
            "title": WL("Talent Cue — 사회자"), "lost": WL("연결 끊김"),
            "show": WL("표시"), "hide": WL("숨기기"), "del": WL("삭제"), "add": WL("추가"), "addShow": WL("추가하고 표시"),
            "new": WL("새 메시지"), "flash": WL("눈에 띄게 (깜빡임)"), "hideMsg": WL("메시지 숨기기"),
            "start": WL("시작"), "pause": WL("일시정지"), "reset": WL("리셋"), "timerOn": WL("타이머 표시"),
            "blackout": WL("블랙아웃"), "messages": WL("메시지"), "timer": WL("타이머"), "min": WL("분"),
            "set": WL("설정"), "delAsk": WL("이 메시지를 삭제할까요?"),
        ])
    }

    private static let html = #"""
<!doctype html><html lang="__LANG__"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Talent Cue</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#151517;color:#eee;font:15px -apple-system,system-ui,sans-serif;padding:12px;max-width:900px;margin:auto}
h1{font-size:17px;margin:4px 0 10px;display:flex;justify-content:space-between;align-items:center}
h2{font-size:13px;color:#999;text-transform:uppercase;letter-spacing:.06em;margin:18px 0 6px}
#pv{position:relative;aspect-ratio:16/9;background:#000;border-radius:8px;overflow:hidden;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;border:1px solid #333}
#pvTitle{position:absolute;top:4%;width:100%;font-size:min(4.5vw,40px);font-weight:600;opacity:.9}
#pvTimer{font-weight:800;font-variant-numeric:tabular-nums;font-size:min(16vw,150px);line-height:1}
#pvMsg{font-weight:700;font-size:min(6vw,56px);padding:2% 4%;border-radius:8px;white-space:pre-wrap}
.blink{animation:b 1s steps(2,start) infinite}@keyframes b{to{visibility:hidden}}
button{font:inherit;border:0;border-radius:8px;padding:9px 13px;background:#2c2c31;color:#fff;cursor:pointer}
button.on{background:#d12b2b}button.go{background:#2f6fe0}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:6px 0}
.msg{display:flex;gap:8px;align-items:center;background:#1f1f23;border-radius:8px;padding:8px;margin:6px 0}
.msg .t{flex:1;white-space:pre-wrap;word-break:break-word}.msg .sw{width:14px;height:14px;border-radius:3px;flex:none}
.msg.live{outline:2px solid #d12b2b}
input[type=text],input[type=number]{font:inherit;background:#232327;color:#fff;border:1px solid #3a3a40;border-radius:8px;padding:8px}
#lost{display:none;color:#ff6b6b}
</style></head><body>
<h1><span id="h"></span><span id="lost"></span></h1>
<div id="pv"><div id="pvTitle"></div><div id="pvTimer"></div><div id="pvMsg"></div></div>
<div class="row"><button id="bo"></button><button id="hm"></button><button id="fl"></button></div>
<h2 id="hT"></h2>
<div class="row"><button id="st" class="go"></button><button id="rs"></button><button data-p="-60">−1</button><button data-p="60">+1</button><button id="tv"></button></div>
<div class="row"><input id="mins" type="number" min="0" max="1440" style="width:90px"> <span id="mn"></span> <button id="set"></button>
 <span id="quick"></span></div>
<h2 id="hM"></h2>
<div class="row"><input id="nt" type="text" style="flex:1;min-width:180px"><input id="nc" type="color" value="#ffffff"><button id="ad"></button><button id="as" class="go"></button></div>
<div id="list"></div>
<script>
const T=__T__,$=id=>document.getElementById(id),K=new URLSearchParams(location.search).get('key')||'';
const lang=document.documentElement.lang,t=k=>T[k][lang=='en'?1:0];
let S=null,sig='';
function cmd(a,extra){const p=new URLSearchParams(Object.assign({key:K,a:a},extra||{}));
 return fetch('/talent/cmd?'+p.toString(),{cache:'no-store'}).then(r=>r.ok?r.json():null).then(s=>{if(s)draw(s)}).catch(()=>{})}
function el(tag,cls,text){const e=document.createElement(tag);if(cls)e.className=cls;if(text!=null)e.textContent=text;return e}
function draw(s){S=s;$('lost').style.display='none';
 const tm=s.timer,live=s.messages.find(m=>m.id==s.live);
 $('pvTitle').textContent=s.blackout?'':s.title;
 $('pvTimer').textContent=(!s.blackout&&tm.visible)?tm.text:'';$('pvTimer').style.color=tm.color;
 $('pvTimer').className=(tm.phase=='overtime')?'blink':'';
 $('pvMsg').textContent=(!s.blackout&&live)?live.text:'';$('pvMsg').style.color=live?live.color:'';
 $('pvMsg').style.outline=(s.flash&&live)?'4px solid #d12b2b':'none';$('pvMsg').className=(s.flash&&live)?'blink':'';
 if(!s.blackout&&!live&&!tm.visible&&s.idle=='clock'){const d=new Date();$('pvTimer').textContent=d.toLocaleTimeString();$('pvTimer').style.color='#ddd';$('pvTimer').className=''}
 $('bo').className=s.blackout?'on':'';$('fl').className=s.flash?'on':'';$('hm').disabled=!live;
 $('st').textContent=tm.running?t('pause'):t('start');$('tv').className=tm.visible?'on':'';
 if(document.activeElement!=$('mins'))$('mins').value=Math.round(tm.duration/60);
 const s2=JSON.stringify([s.messages,s.live]);if(s2==sig)return;sig=s2;
 const l=$('list');l.innerHTML='';
 s.messages.forEach(m=>{const r=el('div','msg'+(m.id==s.live?' live':''));const sw=el('span','sw');sw.style.background=m.color;r.appendChild(sw);
  r.appendChild(el('span','t',m.text));
  const b=el('button',m.id==s.live?'on':'go',m.id==s.live?t('hide'):t('show'));b.onclick=()=>m.id==s.live?cmd('hide'):cmd('show',{id:m.id});r.appendChild(b);
  const d=el('button','',t('del'));d.onclick=()=>{if(confirm(t('delAsk')))cmd('delete',{id:m.id})};r.appendChild(d);l.appendChild(r)})}
function texts(){$('h').textContent=t('title');$('lost').textContent=t('lost');$('bo').textContent=t('blackout');$('hm').textContent=t('hideMsg');
 $('fl').textContent=t('flash');$('hT').textContent=t('timer');$('hM').textContent=t('messages');$('rs').textContent=t('reset');$('tv').textContent=t('timerOn');
 $('mn').textContent=t('min');$('set').textContent=t('set');$('ad').textContent=t('add');$('as').textContent=t('addShow');$('nt').placeholder=t('new');
 const q=$('quick');[5,10,15,20,30,45,60].forEach(m=>{const b=el('button','',m+'′');b.onclick=()=>cmd('set',{sec:m*60});q.appendChild(b)})}
$('bo').onclick=()=>cmd('blackout',{on:S&&S.blackout?0:1});$('hm').onclick=()=>cmd('hide');$('fl').onclick=()=>cmd('flash',{on:S&&S.flash?0:1});
$('st').onclick=()=>cmd(S&&S.timer.running?'pause':'start');$('rs').onclick=()=>cmd('reset');$('tv').onclick=()=>cmd('timer',{on:S&&S.timer.visible?0:1});
document.querySelectorAll('[data-p]').forEach(b=>b.onclick=()=>cmd('plus',{sec:b.dataset.p}));
$('set').onclick=()=>cmd('set',{sec:(+$('mins').value||0)*60});
function add(show){const v=$('nt').value.trim();if(!v)return;cmd('add',{text:v,color:$('nc').value,show:show?1:0}).then(()=>{$('nt').value=''})}
$('ad').onclick=()=>add(false);$('as').onclick=()=>add(true);$('nt').onkeydown=e=>{if(e.key=='Enter')add(false)};
let busy=false;function poll(){if(busy)return;busy=true;const c=new AbortController(),tm=setTimeout(()=>c.abort(),2000);
 fetch('/talent.json?key='+encodeURIComponent(K),{cache:'no-store',signal:c.signal}).then(r=>{if(!r.ok)throw 0;return r.json()}).then(draw)
 .catch(()=>{$('lost').style.display='inline'}).finally(()=>{clearTimeout(tm);busy=false})}
texts();poll();setInterval(poll,500);
</script></body></html>
"""#
}
