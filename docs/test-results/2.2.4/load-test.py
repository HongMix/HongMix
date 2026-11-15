import threading,time,urllib.request,re,subprocess,sys
B='http://127.0.0.1:8088'
stop=time.time()+180; n={'req':0,'err':0}
def loop(path,iv):
    while time.time()<stop:
        try: urllib.request.urlopen(B+path,timeout=3).read(); n['req']+=1
        except Exception: n['err']+=1
        time.sleep(iv)
def thumbs():
    while time.time()<stop:
        for i in range(1,10):
            try: urllib.request.urlopen(B+'/thumb?input=%d&width=240'%i,timeout=3).read(); n['req']+=1
            except Exception: n['err']+=1
        time.sleep(4)
def xml(): return urllib.request.urlopen(B+'/api',timeout=5).read().decode()
def rs(x): return re.search(r'<renderStats avgMs="([\d.]+)" maxMs="([\d.]+)" dropped="(\d+)" uiStallMs="([\d.]+)"',x).groups()
pid=subprocess.check_output(['pgrep','-f','t217/HongMix.app/Contents/MacOS']).split()[0].decode()
print('before',rs(xml()))
ts=[threading.Thread(target=loop,args=('/remote.json',0.3)) for _ in range(2)]+[threading.Thread(target=loop,args=('/tally.json',0.25)) for _ in range(3)]+[threading.Thread(target=thumbs) for _ in range(2)]
[t.start() for t in ts]
cpu=[];mx=0
while time.time()<stop:
    time.sleep(15); c=float(subprocess.check_output(['ps','-o','%cpu=','-p',pid])); cpu.append(c); r=rs(xml()); mx=max(mx,float(r[1])); print(int(stop-time.time()),'cpu',c,'render',r,flush=True)
[t.join() for t in ts]
print('after',rs(xml()),'requests',n,'cpu avg %.1f'%(sum(cpu)/len(cpu)),'render max seen',mx)
