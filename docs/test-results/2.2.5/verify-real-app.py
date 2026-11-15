import json,time,urllib.request,urllib.parse,base64,subprocess,sys
B='http://127.0.0.1:8088'
ok=[];bad=[]
def get(p,auth=None,hdr=None):
    r=urllib.request.Request(B+p,headers=hdr or {})
    if auth: r.add_header('Authorization','Basic '+base64.b64encode(auth.encode()).decode())
    try:
        x=urllib.request.urlopen(r,timeout=5); return x.status,x.read()
    except urllib.error.HTTPError as e: return e.code,e.read()
def api(fn,**kw):
    c,b=get('/api/?'+urllib.parse.urlencode(dict(Function=fn,**kw))); return c
def st(): return json.loads(get('/remote.json')[1])
def chk(name,cond,info=''):
    (ok if cond else bad).append(name); print(('PASS ' if cond else 'FAIL ')+name+(' '+str(info) if info else ''),flush=True)
w=time.sleep
c,b=get('/'); chk('remote page',c==200 and b'const T=' in b and b'__T__' not in b)
c,b=get('/tally'); chk('tally page',c==200 and b'base64,AAAA' in b and b'__NOSLEEP__' not in b)
s=st(); chk('remote.json',len(s['inputs'])>=7,len(s['inputs']))
c,b=get('/thumb?input=1&width=240'); chk('thumbnail',c==200 and b[:2]==b'\xff\xd8')
api('PreviewInput',Input=4);w(.5);s=st();chk('tap = preview',s['preview']==4)
api('Cut');w(.5);s=st();chk('CUT',s['active']==4)
api('CutDirect',Input=2);w(.5);s=st();chk('hold = cut direct',s['active']==2)
api('SetTransitionEffect1',Value='Wipe');api('SetTransitionDuration1',Value=700);s=st();chk('transition select',s['trans'][0]=={'effect':'Wipe','duration':700})
api('PreviewInput',Input=1);api('Transition1');w(1.2);s=st();chk('AUTO',s['active']==1)
for v in (60,128):api('SetFader',Value=v);w(.1)
s=st();chk('T-bar middle',0.4<s['tbar']<0.6,s['tbar'])
api('SetFader',Value=255);w(.5);s=st();chk('T-bar complete',s['tbar']==0 and s['active']==2,(s['tbar'],s['active']))
api('FadeToBlack');w(.3);s=st();chk('FTB on',s['ftb']);api('FadeToBlack');w(1.5);s=st();chk('FTB off',not s['ftb'])
api('OverlayInput2In',Input=8);w(.8);s=st();chk('overlay 2 in',s['overlays'][1]==8)
api('OverlayInput2Out');w(1);s=st();chk('overlay 2 out',s['overlays'][1]==0)
api('Play',Input=5);w(.4);s=st();chk('media play',s['inputs'][4]['playing'])
api('Pause',Input=5);w(.4);s=st();chk('media pause',not s['inputs'][4]['playing'])
api('LoopOff',Input=5);w(.3);s=st();chk('loop off',not s['inputs'][4]['loop']);api('LoopOn',Input=5)
chk('restart',api('Restart',Input=5)==200)
api('SetVolume',Input=1,Value=45);w(.3);s=st();chk('volume',s['inputs'][0]['volume']==45);api('SetVolume',Input=1,Value=80)
api('AudioOff',Input=1);w(.3);s=st();chk('mute',s['inputs'][0]['muted']);api('AudioOn',Input=1)
api('SetMasterVolume',Value=70);w(.3);s=st();chk('master',s['master']['volume']==70);api('SetMasterVolume',Value=100)
t=[i for i in s['inputs'] if 'cd' in i][0]['n']
api('StartCountdown',Input=t);w(2.2);s=st();cd=s['inputs'][t-1];chk('countdown runs',cd['cdRun'] and cd['cd']<299,cd['cd'])
api('AdjustCountdown',Input=t,Value=60);w(.3);s=st();chk('countdown +1 min',s['inputs'][t-1]['cd']>340)
api('StopCountdown',Input=t);w(.3);s=st();chk('countdown stop',s['inputs'][t-1]['cd']==300 and not s['inputs'][t-1]['cdRun'])
api('SetText',Input=8,SelectedName='Headline.Text',Value='Verify 2.2.4');w(.3);s=st();chk('title SetText',s['inputs'][7]['fields'][0]['text']=='Verify 2.2.4')
chk('title IN/OUT',api('TitleBeginAnimation',Input=8,Value='TransitionOut')==200 and api('TitleBeginAnimation',Input=8,Value='TransitionIn')==200)
api('StartRecording');api('StartStreaming');w(3);s=st();chk('REC + STREAM start, timers',s['record']['on'] and s['stream']['on'] and s['record']['sec']>=1,(s['record'],s['stream']))
api('StopRecording');api('StopStreaming');w(2);s=st();chk('REC + STREAM stop',not s['record']['on'] and not s['stream']['on'])
chk('SRT status',len(s['srt'])==1 and s['srt'][0]['connected'],s['srt'])
c,b=get('/tally.json');j=json.loads(b);chk('tally.json',c==200 and j['inputs'][1]['tally']==1)
B2='com.hongseunghoon.HongMix'
subprocess.run(['defaults','write',B2,'apiPassword','v3rify-only']);w(2)
codes={p:get(p)[0] for p in ['/','/remote.json','/api','/thumb?input=1','/tally','/tally.json','/tally.txt']}
chk('password: remote locked, tally open',codes=={'/':401,'/remote.json':401,'/api':401,'/thumb?input=1':401,'/tally':200,'/tally.json':200,'/tally.txt':200},codes)
chk('password: correct password works',get('/remote.json',auth='x:v3rify-only')[0]==200)
chk('tally.json no thumbs with password',json.loads(get('/tally.json')[1])['thumbs'] is False)
subprocess.run(['defaults','delete',B2,'apiPassword']);w(2)
chk('cross-site blocked',get('/tally.json',hdr={'Sec-Fetch-Site':'cross-site'})[0]==403)

c,b=get('/thumb?source=program&width=480'); chk('program monitor picture',c==200 and b[:2]==b'\xff\xd8')
c,b=get('/thumb?source=preview&width=480'); chk('preview monitor picture',c==200 and b[:2]==b'\xff\xd8')
api('SetTransitionEffect2',Value='Merge');api('SetTransitionDuration2',Value=1500);s=st();chk('transition 2 slot',s['trans'][1]=={'effect':'Merge','duration':1500},s['trans'][1])
api('PreviewInput',Input=4);api('Transition2');w(2);s=st();chk('Transition2',s['active']==4)
api('PreviewInput',Input=1);api('QuickPlay',Input=1);w(1.5);s=st();chk('QuickPlay',s['active']==1)
api('OverlayInput3In',Input=8);w(.8);s=st();chk('bank 3 on',s['bank'][2]=={'on':True,'n':8},s['bank'][2])
api('OverlayInput3Out');w(1);s=st();chk('bank 3 saved after out',s['bank'][2]=={'on':False,'n':8},s['bank'][2])
api('OverlayInput3Last');w(.8);s=st();chk('bank 3 Last back on',s['bank'][2]['on']);api('OverlayInput3Out');w(.8)
api('CutDirect',Input=5);api('Play',Input=5);w(1.5);s=st();i5=s['inputs'][4];chk('media pos/dur',i5['dur']>0 and i5['pos']>0,(i5.get('pos'),i5.get('dur')))
api('SetPosition',Input=5,Value=int(i5['dur']*500));w(.6);s=st();chk('SetPosition',abs(s['inputs'][4]['pos']-i5['dur']/2)<2,s['inputs'][4]['pos'])
chk('stats fields',s['fps']>0 and 'renderMs' in s and 'external' in s,(s['fps'],s['renderMs']))
x=get('/api')[1].decode();import re;r=re.search(r'<renderStats avgMs="([\d.]+)" maxMs="([\d.]+)" dropped="(\d+)"',x).groups();chk('no dropped frames',r[2]=='0',r)
print('TOTAL',len(ok),'pass',len(bad),'fail',bad)
