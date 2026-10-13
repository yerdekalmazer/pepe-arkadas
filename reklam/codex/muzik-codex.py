#!/usr/bin/env python3
"""Pepe: özgün 120 BPM müzik ve sentez efektler. Yalnızca Python standart kitaplığı."""
import math, random, wave, sys
from array import array
from pathlib import Path
SR=48000
DURATION=30
N=SR*DURATION
TAU=2*math.pi
rng=random.Random(42)
left=array('f',[0.0])*N
right=array('f',[0.0])*N

def add(start,duration,func,amp=1.0,pan=0.0,echo=False):
    first=int(start*SR); count=min(int(duration*SR),N-first)
    l=math.sqrt((1-pan)/2); r=math.sqrt((1+pan)/2)
    for j in range(max(0,count)):
        x=func(j/SR,j)*amp; k=first+j
        if k<0: continue
        left[k]+=x*l;right[k]+=x*r
        if echo and k+12000<N:
            left[k+12000]+=x*r*.20;right[k+12000]+=x*l*.20

def note(midi):return 440*2**((midi-69)/12)
def pluck(start,midi,amp=.12,pan=0):
    f=note(midi)
    add(start,.7,lambda t,j:(math.sin(TAU*f*t)+.30*math.sin(TAU*f*2*t)+.1*math.sin(TAU*f*3*t))*min(1,t/.008)*math.exp(-7*t),amp,pan,True)
def kick(start):
    add(start,.28,lambda t,j:math.sin(TAU*(48*t+1.65*(1-math.exp(-t*35))))*math.exp(-t*17)*min(1,t/.003),.36)
def hat(start,amp=.05):
    add(start,.065,lambda t,j:rng.uniform(-1,1)*math.exp(-t*65)*min(1,t/.001),amp,.25)
def snare(start):
    add(start,.13,lambda t,j:(rng.uniform(-1,1)*.8+math.sin(TAU*185*t)*.2)*math.exp(-t*28)*min(1,t/.002),.14,-.1)
# A warmly voiced Dmaj7 – Bm7 – Gmaj7 – Aadd9 loop. Every scene is six beats.
chords=[(50,57,61,66),(47,54,57,62),(43,50,54,59),(45,52,59,61)]
for section in range(10):
    start=section*3; ch=chords[section%4]
    for n in ch[1:]:
        f=note(n)
        add(start,3.2,lambda t,j,f=f:math.sin(TAU*f*t)*math.sin(TAU*.13*t+.7)*min(1,t/.25)*min(1,max(0,(3.2-t)/.45)),.055,(-.3 if n%2 else .3))
    for b in range(6):
        tm=start+b*.5
        if tm<28.5:
            kick(tm)
            if b%2:snare(tm)
            for sub in [0,.25]:hat(tm+sub,.038 if sub==0 else .06)
            f=note(ch[0]-12)
            add(tm,.43,lambda t,j,f=f:(math.sin(TAU*f*t)+.18*math.sin(TAU*f*2*t))*min(1,t/.012)*math.exp(-t*7),.22)
    for step in range(12):
        tm=start+step*.25
        if tm<28.6 and step%3!=2:
            midi=ch[1+(step%3)]+12
            pluck(tm,midi,.092 if step%2 else .13,(-.4 if step%2 else .4))
# Editorial cut accents at precisely 3, 6, 9 ... seconds.
for cut in range(3,25,3):
    add(cut-.16,.26,lambda t,j:(rng.uniform(-1,1)*.65+math.sin(TAU*(650*t+1700*t*t))*.35)*math.sin(math.pi*min(1,t/.26))**2,.06,-.2)
# Permission confirmation and reminder arrival.
for tm in [6.7,18.65,21.6]:
    pluck(tm,86,.14,-.15);pluck(tm+.10,93,.1,.2)
# Synthesized puppy bark, no recordings: voiced pulse + band-like formants + breath noise.
def bark(start):
    def sound(t,j):
        env=(1-math.exp(-t*180))*math.exp(-t*16)*min(1,max(0,(.23-t)/.03))
        phase=TAU*(220*t-190*t*t)
        glottal=sum(math.sin(phase*k)/k for k in range(1,8))
        formant=math.sin(TAU*730*t)*.22+math.sin(TAU*1250*t)*.12
        return env*(glottal*.6+formant+rng.uniform(-1,1)*.21)
    add(start,.23,sound,.48,-.12)
# A two-bark motif synchronized with the character's two hops.
bark(15.60);bark(15.94)
# Closing sonic signature and a soft resolved chord.
for tm,m in [(24,74),(24.25,78),(24.5,81),(27,74),(27.25,78),(27.5,86)]:pluck(tm,m,.18)
for m in [50,57,61,66,74]:
    f=note(m)
    add(28.5,1.5,lambda t,j,f=f:math.sin(TAU*f*t)*min(1,t/.02)*math.exp(-t*2),.08,0,True)
# Gentle limiting / fade, deterministic stereo PCM. No third-party modules.
peak=max(max(abs(v) for v in left),max(abs(v) for v in right)); gain=.88/max(peak,.001)
out=array('h')
for i in range(N):
    t=i/SR
    fade=min(1,t/.012,max(0,(30-t)/.48))
    out.append(int(max(-1,min(1,left[i]*gain*fade))*32767))
    out.append(int(max(-1,min(1,right[i]*gain*fade))*32767))
if sys.byteorder!='little':out.byteswap()
path=Path(__file__).resolve().with_name('muzik-codex.wav')
with wave.open(str(path),'wb') as wav:
    wav.setnchannels(2);wav.setsampwidth(2);wav.setframerate(SR);wav.writeframes(out.tobytes())
print(f'{path.name}: {DURATION} s, {SR} Hz, stereo, peak -1.11 dBFS')
