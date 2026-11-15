# 20-minute stability soak for the web remote: browsers polling, tallies, live streams (with churn and a stalled viewer),
# random switching commands; logs HongMix health every 30 s.
import threading,time,random,socket,urllib.request,urllib.parse,re,subprocess,json,sys
B='http://127.0.0.1:8088'; END=time.time()+int(sys.argv[1]); stats={'req':0,'err':0,'frames':0,'cmds':0,'cmd_err':0,'streams_opened':0}
L=threading.Lock()
def inc(k,n=1):
    with L: stats[k]+=n
def get(p,t=5):
    try: r=urllib.request.urlopen(B+p,timeout=t); r.read(); inc('req'); return r.status
    except Exception: inc('err'); return 0
def poller(path,iv):
    while time.time()<END: get(path); time.sleep(iv)
def thumbs():
    while time.time()<END:
        for i in range(1,10): get(f'/thumb?input={i}&width=320')
        time.sleep(3)
def viewer(fps,w,src,life):
    while time.time()<END:
        try:
            s=socket.create_connection(('127.0.0.1',8088),timeout=5); s.sendall(f'GET /stream.mjpg?source={src}&fps={fps}&w={w} HTTP/1.1\r\nHost: x\r\n\r\n'.encode()); inc('streams_opened')
            t0=time.time()
            while time.time()-t0<life and time.time()<END:
                d=s.recv(65536)
                if not d: break
                inc('frames',d.count(b'--hmframe'))
            s.close()
        except Exception: inc('err'); time.sleep(1)
def stalled():
    while time.time()<END:
        s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4096); s.connect(('127.0.0.1',8088))
        s.sendall(b'GET /stream.mjpg?source=program&fps=15&w=854 HTTP/1.1\r\nHost: x\r\n\r\n'); time.sleep(60); s.close()
CMDS=[('PreviewInput',lambda:{'Input':random.randint(1,9)}),('Cut',lambda:{}),('Transition1',lambda:{}),('Transition2',lambda:{}),
 ('CutDirect',lambda:{'Input':random.randint(1,7)}),('OverlayInput1In',lambda:{'Input':8}),('OverlayInput1Out',lambda:{}),('OverlayInput2In',lambda:{'Input':random.choice([3,7,9])}),('OverlayInput2Out',lambda:{}),
 ('Play',lambda:{'Input':random.randint(1,6)}),('Pause',lambda:{'Input':random.randint(3,6)}),('SetVolume',lambda:{'Input':random.randint(1,6),'Value':random.randint(40,100)}),
 ('AudioOff',lambda:{'Input':6}),('AudioOn',lambda:{'Input':6}),('SetFader',lambda:{'Value':random.choice([60,128,200,255])}),('StartCountdown',lambda:{'Input':9}),('AdjustCountdown',lambda:{'Input':9,'Value':30}),
 ('SetText',lambda:{'Input':8,'SelectedName':'Headline.Text','Value':'Soak %d'%random.randint(1,999)}),('QuickPlay',lambda:{'Input':random.randint(1,5)})]
def commander():
    while time.time()<END:
        fn,a=random.choice(CMDS); q=urllib.parse.urlencode(dict(Function=fn,**a()))
        try: urllib.request.urlopen(B+'/api/?'+q,timeout=5).read(); inc('cmds')
        except Exception: inc('cmd_err')
        time.sleep(random.uniform(0.5,2.5))
pid=subprocess.check_output(['pgrep','-f','t217/HongMix.app/Contents/MacOS']).split()[0].decode()
def health():
    x=urllib.request.urlopen(B+'/api',timeout=5).read().decode()
    r=re.search(r'<renderStats avgMs="([\d.]+)" maxMs="([\d.]+)" dropped="(\d+)"',x).groups()
    ps=subprocess.check_output(['ps','-o','%cpu=,rss=','-p',pid]).decode().split()
    th=len(subprocess.run(['ps','-M','-p',pid],capture_output=True,text=True).stdout.splitlines())-1
    est=len(subprocess.run(['lsof','-nP','-a','-p',pid,'-iTCP:8088','-sTCP:ESTABLISHED'],capture_output=True,text=True).stdout.strip().splitlines())
    out=json.loads(urllib.request.urlopen(B+'/remote.json',timeout=5).read())
    return dict(render_avg=float(r[0]),render_max=float(r[1]),dropped=int(r[2]),cpu=float(ps[0]),rss_mb=int(ps[1])//1024,threads=th,conns=max(0,est-1),stream=out['stream']['on'],rec=out['record']['on'])
ts=[threading.Thread(target=poller,args=('/remote.json',0.4)),threading.Thread(target=poller,args=('/remote.json',0.7)),
    *[threading.Thread(target=poller,args=('/tally.json',0.25)) for _ in range(3)],threading.Thread(target=thumbs),
    threading.Thread(target=viewer,args=(15,854,'program',45)),threading.Thread(target=viewer,args=(15,854,'preview',45)),
    threading.Thread(target=viewer,args=(8,480,'program',20)),threading.Thread(target=viewer,args=(2,320,'preview',30)),
    threading.Thread(target=stalled),threading.Thread(target=commander),threading.Thread(target=commander)]
for t in ts: t.daemon=True; t.start()
t0=time.time()
while time.time()<END:
    time.sleep(30); h=health(); print(json.dumps(dict(t=int(time.time()-t0),**h,**stats)),flush=True)
time.sleep(3); print('FINAL',json.dumps(dict(**health(),**stats)),flush=True)
