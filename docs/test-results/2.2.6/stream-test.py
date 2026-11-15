import socket,time,threading,re,sys,json,urllib.request
def watch(path,secs,out):
    s=socket.create_connection(('127.0.0.1',8088),timeout=5); s.sendall(f'GET {path} HTTP/1.1\r\nHost: 127.0.0.1:8088\r\n\r\n'.encode())
    t0=time.time();n=0;b=0;buf=b'';sizes=[];first=None
    while time.time()-t0<secs:
        try: d=s.recv(65536)
        except socket.timeout: break
        if not d: break
        b+=len(d);buf+=d
        while True:
            m=re.search(rb'Content-Length: (\d+)\r\n\r\n',buf)
            if not m or len(buf)<m.end()+int(m.group(1)): break
            jpg=buf[m.end():m.end()+int(m.group(1))]; assert jpg[:2]==b'\xff\xd8'
            if first is None: first=time.time()-t0
            n+=1;sizes.append(len(jpg));buf=buf[m.end()+int(m.group(1)):]
    s.close(); el=time.time()-t0
    out.append(dict(path=path,fps=round(n/el,1),mbps=round(b*8/el/1e6,2),kb=round(sum(sizes)/max(1,len(sizes))/1024,1),first=round(first or -1,2)))
def rs():
    x=urllib.request.urlopen('http://127.0.0.1:8088/api').read().decode()
    return re.search(r'<renderStats avgMs="([\d.]+)" maxMs="([\d.]+)" dropped="(\d+)"',x).groups()
mode=sys.argv[1]
if mode=='profiles':
    for fps,w in [(15,854),(15,480),(8,640),(8,400),(2,480),(2,320)]:
        out=[]; watch(f'/stream.mjpg?source=program&fps={fps}&w={w}',8,out); print(out[0],flush=True)
else:
    n=int(sys.argv[2]); out=[]; print('before',rs())
    ts=[threading.Thread(target=watch,args=(f'/stream.mjpg?source={"program" if i%2==0 else "preview"}&fps=15&w=854',60,out)) for i in range(n)]
    [t.start() for t in ts]; time.sleep(30); pid=__import__('subprocess').check_output(['pgrep','-f','t217/HongMix.app/Contents/MacOS']).split()[0].decode()
    print('cpu',__import__('subprocess').check_output(['ps','-o','%cpu=','-p',pid]).decode().strip()); [t.join() for t in ts]
    for o in out: print(o)
    print('after',rs())
