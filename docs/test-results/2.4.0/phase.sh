#!/bin/zsh
# phase <label> <seconds> [sampleMain]
SP=$SCRATCH; P=$SP/rp; L=$1; S=$2
PID=$(pgrep -x HongMix)
st() { curl -s -m2 http://127.0.0.1:8088/api/ ; }
d0=$(st | grep -o 'dropped="[0-9]*"' | grep -o '[0-9]*')
(python3 -I $SP/gpuproc.py $S > $P/$L.gpu &)
[ -n "$3" ] && (sample $PID 6 -mayDie -file $P/$L.sample >/dev/null 2>&1 &)
: > $P/$L.s
for k in $(seq 1 $S); do x=$(st)
 echo "$(echo "$x" | grep -o '<renderStats[^>]*' | sed -E 's/.*avgMs="([^"]*)" maxMs="([^"]*)" dropped="([^"]*)" uiStallMs="([^"]*)" outputMonitorFps="([^"]*)".*/\1 \2 \3 \4 \5/') $(echo "$x" | grep -o '<inputStats number="9"[^>]*' | grep -o 'measuredFps="[^"]*"\|maxGapMs="[^"]*"' | grep -o '[0-9.]*' | tr '\n' ' ') $(ps -o %cpu= -p $PID)" >> $P/$L.s
 perl -e 'select(undef,undef,undef,0.95)'; done
sleep 1
python3 -I - $P/$L.s $L $d0 <<'PY'
import sys,statistics as s
rows=[list(map(float,l.split())) for l in open(sys.argv[1]) if len(l.split())==8]
a,m,d,u,o,f,g,c=zip(*rows)
print(f"{sys.argv[2]:10s} drops+{int(d[-1]-float(sys.argv[3]))} | render avg {s.mean(a):.2f} worst {max(m):.1f}ms | UI stall avg {s.mean(u):.0f} max {max(u):.0f}ms (>100ms in {sum(1 for x in u if x>100)}/{len(u)}s) | outMon fps min {min(o):.0f} | replay input fps {s.mean(f):.1f} worstGap {max(g):.0f}ms | CPU {s.mean(c):.0f}%")
PY
head -3 $P/$L.gpu | sed 's/^/     /'
