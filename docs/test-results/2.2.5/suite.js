(async()=>{
const w=ms=>new Promise(r=>setTimeout(r,ms));const st=()=>fetch('/_state').then(r=>r.json());const R=[];const ok=(n,c,i)=>R.push((c?'PASS ':'FAIL ')+n+(i!==undefined&&!c?' → '+JSON.stringify(i):''));
const vis=e=>!!e&&e.offsetParent!==null&&getComputedStyle(e).visibility!='hidden';
const tileEl=n=>document.querySelector('.tile[data-n="'+n+'"]');const tb=(n,a)=>tileEl(n).querySelector('[data-a="'+a+'"]');
const lastCall=async()=>{const l=await fetch('/_log').then(r=>r.json());return l[l.length-1]};
const clickVis=(...ids)=>{for(const id of ids){const e=$(id);if(vis(e)){e.click();return true}}return false};
await fetch('/_reset');await w(400);if(L!='desk')setView('sw');await w(900);
ok('layout '+L+' / page fits the screen',innerWidth==(window.__expW||innerWidth)&&document.documentElement.scrollWidth<=innerWidth+1,[document.documentElement.scrollWidth,innerWidth,window.__expW]);
ok('monitors visible',vis($('pvw'))&&vis($('pgm')));
ok('tiles rendered',document.querySelectorAll('.tile').length==8);
tileEl(4).querySelector('.scr').click();await w(500);let s=await st();ok('tap tile → Preview',s.preview==4,s.preview);
ok('CUT button visible',clickVis('cut','cut2'));await w(500);s=await st();ok('CUT',s.active==4&&s.preview==1,[s.active,s.preview]);
tb(2,'cut').click();await w(500);s=await st();ok('tile Cut → Program',s.active==2,s.active);
tb(5,'pp').click();await w(600);s=await st();ok('tile ▶ play',s.inputs[4].playing);
await w(500);tb(5,'pp').click();await w(600);s=await st();ok('tile ❚❚ pause',!s.inputs[4].playing);
tb(5,'loop').click();await w(600);s=await st();ok('tile Loop off',!s.inputs[4].loop);tb(5,'loop').click();await w(600);
s=await st();ok('tile Loop on',s.inputs[4].loop);
tb(5,'re').click();await w(400);ok('tile ⏮ restart',(await lastCall())[0]=='Restart');
tb(1,'mute').click();await w(600);s=await st();ok('tile mute',s.inputs[0].muted);tb(1,'mute').click();await w(600);s=await st();ok('tile unmute',!s.inputs[0].muted);
ok('Music has no Cut-disabled: loop enabled for audio media',!tb(6,'loop').disabled);
ok('camera ▶ disabled (not media)',tb(1,'pp').disabled);
tileEl(7).querySelector('.ov[data-c="1"]').click();await w(600);s=await st();ok('tile overlay 1 in',s.bank[0].on&&s.bank[0].n==7,s.bank[0]);
await w(300);ok('tile overlay 1 lit',tileEl(7).querySelector('.ov[data-c="1"]').classList.contains('live'));
tileEl(7).querySelector('.ov[data-c="1"]').click();await w(600);s=await st();ok('tile overlay 1 out',!s.bank[0].on);
tileEl(3).querySelector('.ov[data-c="2"]').click();await w(600);s=await st();ok('tile overlay 2 in (row 1)',s.bank[1].on&&s.bank[1].n==3);
if(L!='phone'){tileEl(3).querySelector('.ov[data-c="6"]').click();await w(600);s=await st();ok('tile overlay 6 in (row 2)',s.bank[5].on&&s.bank[5].n==3)}
else ok('phone hides overlay 5–8 row',!vis(tileEl(3).querySelector('.ov[data-c="6"]')));
// center column (phone: More tab)
if(L=='phone'){setView('more');await w(700)}
const bank=[...$('bank').children];ok('OVERLAY bank visible',vis(bank[0]));
bank[1].click();await w(600);s=await st();ok('bank 2 out (was on)',!s.bank[1].on);
bank[1].click();await w(600);s=await st();ok('bank 2 Last → back on',s.bank[1].on&&s.bank[1].n==3);
bank[2].click();await w(500);ok('bank empty → hint, no call',(await lastCall())[0]!='OverlayInput3Last'&&$('toast').textContent.length>5);
const tr2=document.querySelector('.trow[data-s="2"]');const[go2,ef2,du2]=tr2.children;ef2.value='Wipe';ef2.dispatchEvent(new Event('change'));await w(500);
du2.value='1500';du2.dispatchEvent(new Event('change'));await w(600);s=await st();ok('transition 2 effect/time',s.trans[1].effect=='Wipe'&&s.trans[1].duration==1500,s.trans[1]);
await w(400);ok('transition 2 button label',go2.textContent=='Wipe',go2.textContent);
s=await st();const pv=s.preview;go2.click();await w(600);s=await st();ok('transition 2 → Program',s.active==pv,[s.active,pv]);
s=await st();const pv2=s.preview;$('qp').click();await w(600);s=await st();ok('Quick Play',s.active==pv2);
const t=$('tbar');t.dispatchEvent(new PointerEvent('pointerdown'));for(const v of [60,128]){t.value=v;t.dispatchEvent(new Event('input'));await w(90)}await w(300);s=await st();ok('T-Bar middle',s.tbar>0.4&&s.tbar<0.6,s.tbar);
s=await st();const pv3=s.preview;for(const v of [200,255]){t.value=v;t.dispatchEvent(new Event('input'));await w(90)}t.dispatchEvent(new Event('change'));await w(800);s=await st();ok('T-Bar complete, back to 0',s.active==pv3&&s.tbar==0&&+t.value==0,[s.active,pv3,s.tbar,t.value]);
clickVis('ftb','ftb2');await w(500);s=await st();ok('FTB on',s.ftb);clickVis('ftb','ftb2');await w(500);s=await st();ok('FTB off',!s.ftb);
if(L=='phone'){setView('sw');await w(700);clickVis('go1');await w(500);ok('phone strip transition 1',(await lastCall())[0]=='Transition1')}
// program transport
tb(4,'cut').click();await w(900);ok('PROGRAM transport for media',vis($('trp').querySelector('[data-a=pp]')));
$('trp').querySelector('[data-a=pp]').click();await w(600);s=await st();ok('PROGRAM ▶',s.inputs[3].playing);
const bar=$('trp').querySelector('.bar'),r=bar.getBoundingClientRect();bar.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:r.left+r.width/2,clientY:r.top+5}));await w(500);
const lc=await lastCall();ok('PROGRAM seek',lc[0]=='SetPosition'&&Math.abs(+lc[1].Value-45000)<3000,lc);
tb(1,'cut').click();await w(900);ok('no transport for camera',$('trp').style.visibility=='hidden');
// outputs with confirmation
$('oStream').click();await w(200);ok('STREAM asks first',$('cf').classList.contains('show')&&$('cfOk').className=='ok');$('cfNo').click();await w(400);s=await st();ok('cancel = not started',!s.stream.on);
$('oStream').click();await w(200);$('cfOk').click();await w(1300);s=await st();ok('STREAM start',s.stream.on);
await w(500);ok('STREAM lit + time',$('oStream').classList.contains('on2')&&/\d:\d\d/.test($('oStream').textContent),$('oStream').textContent);
$('oStream').click();await w(200);ok('stop dialog is red',$('cfOk').className=='danger'&&$('cfB').textContent.length>5);$('cfOk').click();await w(700);s=await st();ok('STREAM stop',!s.stream.on);
$('oRec').click();await w(200);$('cfOk').click();await w(700);s=await st();ok('REC start',s.record.on);$('oRec').click();await w(200);$('cfOk').click();await w(700);s=await st();ok('REC stop',!s.record.on);
$('oExt').click();await w(300);ok('EXTERNAL not set up → hint, no dialog',!$('cf').classList.contains('show')&&$('toast').textContent.length>5);
// audio
if(L=='desk')setSide('au');else setView('au');await w(800);
const row=k=>document.querySelector('.ch[data-k="'+k+'"]');ok('mixer visible',vis(row('M')));
const rg=row(2).querySelector('input');rg.dispatchEvent(new PointerEvent('pointerdown'));rg.value=37;rg.dispatchEvent(new Event('input'));rg.dispatchEvent(new Event('change'));await w(600);s=await st();ok('fader input 2',s.inputs[1].volume==37,s.inputs[1].volume);
row(2).querySelector('.mb').click();await w(600);s=await st();ok('mixer M mute',s.inputs[1].muted);row(2).querySelector('.mb').click();await w(500);
const mr=row('M').querySelector('input');mr.value=70;mr.dispatchEvent(new Event('input'));await w(500);s=await st();ok('Master fader',s.master.volume==70);
row('M').querySelector('.mb').click();await w(500);s=await st();ok('Master mute',s.master.muted);row('M').querySelector('.mb').click();await w(400);
ok('meters move',[...document.querySelectorAll('.mt i')].some(i=>parseFloat(i.style.width)>5));
$('cdStart').click();await w(1300);s=await st();ok('countdown start',s.inputs[7].cdRun&&s.inputs[7].cd<300);
$('cdPlus').click();await w(500);s=await st();ok('countdown +1 min',s.inputs[7].cd>340);$('cdStop').click();await w(500);s=await st();ok('countdown stop',!s.inputs[7].cdRun&&s.inputs[7].cd==300);
// titles via tile Edit
if(L!='desk'){setView('sw');await w(700)}
tb(7,'edit').click();await w(900);ok('Edit opens Titles for that input',vis($('pTi'))&&$('tSel').value=='7');
const f=$('fields').querySelectorAll('input');ok('field labels without .Text',$('fields').querySelector('.fl').textContent=='Headline');
f[0].value='Test Name';f[0].dispatchEvent(new Event('input'));await w(1500);ok('typing kept while polling',f[0].value=='Test Name'&&vis($('unsaved')));
$('apply').click();await w(900);s=await st();ok('Apply → SetText',s.inputs[6].fields[0].text=='Test Name');
$('next').click();await w(600);s=await st();ok('preset next',s.inputs[6].preset==1);
$('tin').click();await w(300);ok('IN',(await lastCall())[1].Value=='TransitionIn');
$('tovl').click();await w(600);s=await st();ok('Titles overlay 1',s.bank[0].on&&s.bank[0].n==7);$('tovl').click();await w(500);
// help + language
$('helpB').click();await w(200);ok('help opens',$('hp').classList.contains('show')&&$('hpL').children.length==10);$('hpC').click();
document.querySelector('#lang [data-l=en]').click();await w(500);ok('EN switch',$('inT').textContent=='Input'&&document.documentElement.lang=='en');
document.querySelector('#lang [data-l=ko]').click();await w(300);ok('KO switch',$('inT').textContent=='입력');
if(L!='desk')setView('sw');await w(300);
const fails=R.filter(x=>x.startsWith('FAIL'));window.__suite={layout:L,total:R.length,fails,all:R};
})();
'started'
