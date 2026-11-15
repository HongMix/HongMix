# Mock HongMix HTTP API for testing the web remote page virtually (no app needed).
# Serves the page straight from WebRemotePage.swift / WebRemote.swift (KO+EN strings from en.json),
# simulates the switcher state, logs every function call (GET /_log, POST-less reset via /_reset).
import http.server, json, re, time, urllib.parse, os, threading
from pathlib import Path
REPO = str(Path(__file__).resolve().parents[3])
HERE = os.path.dirname(os.path.abspath(__file__))
EN = json.load(open(REPO + '/Resources/en.json', encoding='utf-8'))
LANG = os.environ.get('MOCK_LANG', 'ko')

def page(name, swift):
    s = open(REPO + '/Sources/App/Engine/' + swift, encoding='utf-8').read()
    html = re.search(r'private static let ' + name + r' = #"""\n(.*?)\n"""#', s, re.S).group(1)
    body = re.search(r'fill\(' + name + r', \[(.*?)\]\)', s, re.S).group(1)
    T = {k: [ko, EN.get(ko, ko)] for k, ko in re.findall(r'"(\w+)": WL\("((?:[^"\\]|\\.)*)"\)', body)}
    html = html.replace('__T__', json.dumps(T, ensure_ascii=False).replace('</', '<\\/')).replace('__LANG__', LANG)
    if name == 'tallyHTML':
        b = re.search(r'noSleepVideo = "([^"]+)"', s).group(1); html = html.replace('__NOSLEEP__', b)
    return html

def fresh():
    ins = [dict(n=1, title='Camera A', type='Capture', img='cam1'), dict(n=2, title='Camera B', type='Capture', img='cam2'),
           dict(n=3, title='SRT Remote', type='Stream', img='bars'), dict(n=4, title='Clip', type='Video', img='30_png_1080p_opaque', media=True, dur=90.0),
           dict(n=5, title='Vertical phone', type='Video', img='vert', media=True, dur=20.0), dict(n=6, title='Music', type='Audio', img=None, media=True, dur=200.0),
           dict(n=7, title='Lower Third', type='GT', img='lt', fields=[{'name': 'Headline.Text', 'text': 'Jane Doe'}, {'name': 'Description.Text', 'text': 'Host'}], presets=3, preset=0),
           dict(n=8, title='Countdown', type='GT', img='31_png_alpha_corner_logo', fields=[{'name': 'Label.Text', 'text': 'BREAK'}], presets=0, preset=-1, cd=300.0)]
    for i in ins:
        i.update(tally=0, muted=False, volume=80, m1=0.0, m2=0.0, audio=i['type'] not in ('GT', 'Image', 'Colour'))
        if i.get('media'): i.update(playing=False, loop=True, pos=0.0)
        if 'cd' in i: i['cdRun'] = False
    return dict(format='1080p 29.97', fps=29.97, active=1, preview=2, bank=[{'on': False, 'n': 0} for _ in range(8)], ftb=False, tbar=0.0,
                transitioning=False, trans=[{'effect': e, 'duration': d} for e, d in [('Fade', 500), ('Merge', 1000), ('Wipe', 1000), ('Fly', 1000)]],
                renderMs=2.9, renderMax=4.6, dropped=0, srt=[{'n': 3, 'connected': True, 'rtt': 5.2, 'loss': 0.0, 'drops': 0}], inputs=ins,
                master={'volume': 100, 'muted': False, 'm1': 0.3, 'm2': 0.3},
                stream={'on': False, 'sec': 0, 'has': True}, record={'on': False, 'sec': 0, 'has': True}, external={'on': False, 'sec': 0, 'has': False},
                _t={'stream': 0, 'record': 0, 'external': 0}, log=[])

S = fresh(); LOCK = threading.Lock()
def inp(n):
    for i in S['inputs']:
        if str(i['n']) == str(n): return i
def tally():
    on = [b['n'] for b in S['bank'] if b['on']]
    for i in S['inputs']:
        i['tally'] = 1 if (i['n'] == S['active'] or i['n'] in on) else 2 if i['n'] == S['preview'] else 0
def tick():
    now = time.time()
    for i in S['inputs']:
        if i.get('media') and i['playing']:
            i['pos'] += 0.4
            if i['pos'] >= i['dur']: i['pos'] = 0.0 if i['loop'] else i['dur']; i['playing'] = i['loop']
        if i.get('cdRun'): i['cd'] = max(0.0, i['cd'] - 0.4)
        lvl = 0.25 if (i['audio'] and (i.get('playing') or not i.get('media'))) else 0.0
        i['m1'] = i['m2'] = round(lvl * (0.6 + 0.4 * ((now * 7 + i['n']) % 1)), 3)
    for k in ('stream', 'record', 'external'):
        if S[k]['on']: S[k]['sec'] = int(now - S['_t'][k])

def cut(to):
    S['preview'], S['active'] = S['active'], to
def perform(fn, q):
    f = fn.lower(); n = q.get('Input'); v = q.get('Value', '')
    i = inp(n) if n else None
    m = re.match(r'overlayinput(\d)(in|out|last)?$', f)
    if m:
        c = int(m.group(1)) - 1; act = m.group(2)
        if act == 'out': S['bank'][c]['on'] = False
        elif act == 'last':
            if not S['bank'][c]['n']: return 'No saved input'
            S['bank'][c]['on'] = True
        else:
            if not i: return 'Input required'
            if act is None and S['bank'][c]['on'] and S['bank'][c]['n'] == i['n']: S['bank'][c]['on'] = False
            else: S['bank'][c] = {'on': True, 'n': i['n']}
        return None
    m = re.match(r'(settransitioneffect|settransitionduration|transition)(\d)$', f)
    if m:
        k = int(m.group(2)) - 1
        if m.group(1) == 'transition': cut(S['preview']); return None
        if m.group(1) == 'settransitioneffect': S['trans'][k]['effect'] = v
        else: S['trans'][k]['duration'] = int(v)
        return None
    if f == 'previewinput': S['preview'] = i['n']
    elif f == 'cut': cut(S['preview'])
    elif f in ('cutdirect', 'quickplay'): S['active'] = i['n']
    elif f == 'setfader':
        x = int(v) / 255
        if x >= 0.999: cut(S['preview']); S['tbar'] = 0.0
        else: S['tbar'] = round(x, 3)
    elif f == 'fadetoblack': S['ftb'] = not S['ftb']
    elif f == 'play': i['playing'] = True
    elif f == 'pause': i['playing'] = False
    elif f == 'restart': i['pos'] = 0.0
    elif f == 'loopon': i['loop'] = True
    elif f == 'loopoff': i['loop'] = False
    elif f == 'setposition': i['pos'] = int(v) / 1000
    elif f == 'audioon': i['muted'] = False
    elif f == 'audiooff': i['muted'] = True
    elif f == 'setvolume': i['volume'] = int(v)
    elif f == 'setmastervolume': S['master']['volume'] = int(v)
    elif f == 'masteraudioon': S['master']['muted'] = False
    elif f == 'masteraudiooff': S['master']['muted'] = True
    elif f in ('startstreaming', 'stopstreaming', 'startrecording', 'stoprecording', 'startexternal', 'stopexternal'):
        k = {'stream': 'stream', 'record': 'record', 'xtern': 'external'}[f[-9:-4] if 'stream' in f else ('record' if 'record' in f else 'xtern')] if False else ('stream' if 'stream' in f else 'record' if 'record' in f else 'external')
        on = f.startswith('start'); S[k]['on'] = on; S[k]['sec'] = 0; S['_t'][k] = time.time()
    elif f == 'startcountdown': i['cdRun'] = True
    elif f == 'pausecountdown': i['cdRun'] = not i['cdRun']
    elif f == 'stopcountdown': i['cdRun'] = False; i['cd'] = 300.0
    elif f == 'adjustcountdown': i['cd'] = max(0.0, i['cd'] + float(v))
    elif f == 'settext':
        for fl in i['fields']:
            if fl['name'] == q.get('SelectedName'): fl['text'] = v
    elif f in ('nexttitlepreset', 'previoustitlepreset'):
        if not i['presets']: return 'No presets'
        i['preset'] = (i['preset'] + (1 if f.startswith('next') else -1)) % i['presets']
    elif f == 'titlebeginanimation': pass
    else: return 'Unknown function ' + fn
    return None

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, ct, body):
        if isinstance(body, str): body = body.encode()
        self.send_response(code); self.send_header('Content-Type', ct); self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store'); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        global S
        u = urllib.parse.urlparse(self.path); p = u.path.lower(); q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        with LOCK:
            if p == '/': return self.send(200, 'text/html; charset=utf-8', page('remoteHTML', 'WebRemotePage.swift'))
            if p == '/tally': return self.send(200, 'text/html; charset=utf-8', page('tallyHTML', 'WebRemote.swift'))
            if p == '/remote.json':
                tick(); tally(); s = {k: v for k, v in S.items() if k not in ('_t', 'log')}
                s['overlays'] = [b['n'] if b['on'] else 0 for b in S['bank']]
                s['inputs'] = [{k: v for k, v in i.items() if k != 'img'} for i in S['inputs']]
                return self.send(200, 'application/json', json.dumps(s))
            if p == '/tally.json':
                tally(); return self.send(200, 'application/json', json.dumps({'active': S['active'], 'preview': S['preview'], 'overlays': [b['n'] if b['on'] else 0 for b in S['bank']],
                    'inputs': [{'n': i['n'], 'title': i['title'], 'tally': i['tally']} for i in S['inputs']], 'thumbs': True}))
            if p == '/thumb':
                src = q.get('source'); n = S['active'] if src == 'program' else S['preview'] if src == 'preview' else q.get('input')
                i = inp(n)
                if not i or not i['img']: return self.send(404, 'text/plain', 'no picture')
                return self.send(200, 'image/jpeg', open(HERE + '/img/' + i['img'] + '.jpg', 'rb').read())
            if p == '/api' or p == '/api/':
                fn = q.get('function') or q.get('Function')
                q2 = {k[0].upper() + k[1:]: v for k, v in q.items()}
                q2.update({k: v for k, v in urllib.parse.parse_qs(u.query).items() for v in v[:1]})
                err = perform(fn, q2); S['log'].append([fn, {k: v for k, v in q2.items() if k != 'Function'}, err])
                return self.send(500 if err else 200, 'text/plain', err or 'Function completed successfully.')
            if p == '/_suite.js': return self.send(200, 'text/javascript', open(HERE + '/suite.js', encoding='utf-8').read())
            if p == '/_log': return self.send(200, 'application/json', json.dumps(S['log']))
            if p == '/_reset': S = fresh(); return self.send(200, 'text/plain', 'reset')
            if p == '/_state': return self.send(200, 'application/json', json.dumps({k: v for k, v in S.items() if k != '_t'}))
        self.send(404, 'text/plain', 'not found')

http.server.ThreadingHTTPServer(('127.0.0.1', int(os.environ.get('MOCK_PORT', '8095'))), H).serve_forever()
