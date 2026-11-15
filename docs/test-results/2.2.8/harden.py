import socket,time,subprocess,re,urllib.request
H='127.0.0.1';P=8088
def est():
    pid=subprocess.check_output(['pgrep','-f','t217/HongMix.app/Contents/MacOS']).split()[0].decode()
    o=subprocess.run(['lsof','-nP','-a','-p',pid,'-iTCP:8088','-sTCP:ESTABLISHED'],capture_output=True,text=True).stdout
    return max(0,len(o.strip().splitlines())-1)
def stream(q,rcvbuf=None):
    s=socket.socket();
    if rcvbuf: s.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,rcvbuf)
    s.connect((H,P)); s.sendall(f'GET /stream.mjpg?{q} HTTP/1.1\r\nHost: x\r\n\r\n'.encode()); return s
def status(s,t=3):
    s.settimeout(t); d=s.recv(200); return d.split(b'\r\n')[0].decode()
R=[]
# 1 fps snapping: fps=7 should give 8
s=stream('source=program&fps=7&w=500'); s.settimeout(5); t0=time.time();n=0;buf=b''
while time.time()-t0<4:
    buf+=s.recv(65536)
n=buf.count(b'--hmframe'); s.close(); R.append(('fps 7 snapped to 8', 28<=n<=36, n))
# 2 viewer cap 16
socks=[stream('source=program&fps=2&w=320') for _ in range(16)]; time.sleep(1)
x=stream('source=program&fps=2&w=320'); st=status(x); R.append(('17th viewer refused (503)', '503' in st, st)); x.close()
for s in socks: s.close()
time.sleep(2); R.append(('connections released after close', est()<=1, est()))
# 3 stalled viewer (stops reading) dropped
base=est(); s=stream('source=program&fps=15&w=854',rcvbuf=4096); time.sleep(1.5); s.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4096)
t0=time.time(); gone=None
while time.time()-t0<40:
    if est()<=base: gone=round(time.time()-t0,1); break
    time.sleep(1)
R.append(('stalled viewer dropped by HongMix', gone is not None, gone)); s.close()
# 4 split request headers
s=socket.create_connection((H,P)); s.sendall(b'GET /remote.json HTTP/1.1\r\nHo'); time.sleep(0.4); s.sendall(b'st: x\r\n\r\n'); st=status(s); R.append(('request in two TCP pieces', '200' in st, st)); s.close()
# 5 idle connection closed
s=socket.create_connection((H,P)); s.settimeout(15); t0=time.time()
try: d=s.recv(10); closed=(d==b'')
except Exception as e: closed=False
R.append(('idle connection closed ~10 s', closed and 8<time.time()-t0<13, round(time.time()-t0,1))); s.close()
# 6 same-site blocked, same-origin ok, none ok
def code(h):
    r=urllib.request.Request('http://127.0.0.1:8088/remote.json',headers=h)
    try: return urllib.request.urlopen(r,timeout=5).status
    except urllib.error.HTTPError as e: return e.code
R.append(('same-site blocked', code({'Sec-Fetch-Site':'same-site'})==403, code({'Sec-Fetch-Site':'same-site'})))
R.append(('same-origin allowed', code({'Sec-Fetch-Site':'same-origin'})==200, None)); R.append(('typed address (none) allowed', code({'Sec-Fetch-Site':'none'})==200, None))
x=urllib.request.urlopen('http://127.0.0.1:8088/api').read().decode(); d=re.search(r'dropped="(\d+)"',x).group(1); R.append(('no dropped frames',d=='0',d))
for name,ok,info in R: print(('PASS ' if ok else 'FAIL ')+name, '' if info is None else info)
