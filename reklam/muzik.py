# Arka plan: yavaş, sade bir piyano + iki yerde Pepe'nin havlaması. Telifsiz, burada sentezlenir.
import math, random, struct, wave
SR, DUR = 44100, 61.0
N = int(SR * DUR)
L = [0.0] * N; R = [0.0] * N
def add(i, l, r):
    if 0 <= i < N: L[i] += l; R[i] += r
def hz(m): return 440 * 2 ** ((m - 69) / 12)
def piano(t0, m, amp, pan=0.5, dur=3.2):
    # Birkaç harmonik, hızlı atak, uzun sönüm; tiz harmonikler daha çabuk söner.
    f = hz(m); a0 = int(t0 * SR)
    for i in range(a0, min(N, a0 + int(dur * SR))):
        t = (i - a0) / SR
        env = min(1, t / 0.006) * math.exp(-t * 1.4)
        v = env * (math.sin(2 * math.pi * f * t)
                   + 0.35 * math.exp(-t * 2) * math.sin(2 * math.pi * 2 * f * t)
                   + 0.12 * math.exp(-t * 4) * math.sin(2 * math.pi * 3 * f * t))
        add(i, amp * v * (1 - pan), amp * v * pan)
# 66 bpm civarı; Fmaj7 · Am7 · Dmaj7(no3)/Bb · C, her akor 3.6 sn.
chords = [(41, [60, 64, 67, 69]), (45, [60, 64, 67, 72]), (46, [62, 65, 69, 72]), (48, [60, 64, 67, 71])]
step, beat = 3.6, 0.9
k = 0
t = 0.6
while t < DUR - 4:
    bass, notes = chords[k % 4]
    piano(t, bass, 0.10, 0.45, 4)
    piano(t, bass + 12, 0.05, 0.45, 4)
    order = [0, 2, 1, 3] if k % 2 == 0 else [0, 1, 2, 3]
    for j, n in enumerate(order):
        piano(t + j * beat, notes[n] + 12, 0.045 if j else 0.06, 0.35 + 0.1 * j)
    t += step; k += 1
# Kapanış: tek, uzun bir akor
for m, a in [(41, .1), (53, .05), (60, .05), (64, .05), (69, .05), (72, .04)]:
    piano(55.2, m, a, 0.5, 6)
def bark(t0, f=520, amp=0.16):
    a0 = int(t0 * SR); ph = 0; d = 0.14; rnd = random.Random(7)
    for i in range(a0, a0 + int(d * SR)):
        t = (i - a0) / SR; k = t / d
        fr = f * (1 + 0.7 * math.sin(math.pi * min(1, k * 1.6)))
        ph += 2 * math.pi * fr / SR
        env = min(1, k * 25) * (1 - k) ** 1.5
        v = env * (0.6 * math.sin(ph) + 0.3 * math.sin(2 * ph) + 0.15 * math.sin(3 * ph) + 0.12 * (rnd.random() * 2 - 1))
        add(i, amp * v, amp * v)
# "İş bitince havlıyor" sahnesi
bark(32.4, 540); bark(32.62, 600)
# Basit oda yankısı: gecikmeli, kısık kopyalar
for d, g in [(0.083, .22), (0.131, .16), (0.197, .1)]:
    o = int(d * SR)
    for i in range(N - 1, o - 1, -1):
        L[i] += g * R[i - o]; R[i] += g * L[i - o]
for i in range(int((DUR - 3) * SR), N):
    g = (N - i) / (3 * SR); L[i] *= g; R[i] *= g
for i in range(int(0.6 * SR)):
    g = i / (0.6 * SR); L[i] *= g; R[i] *= g
peak = max(max(abs(x) for x in L), max(abs(x) for x in R))
g = 0.8 / peak
with wave.open('muzik.wav', 'w') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(b''.join(struct.pack('<hh', int(L[i] * g * 32767), int(R[i] * g * 32767)) for i in range(N)))
print('ok')
