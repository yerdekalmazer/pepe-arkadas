# Arka plan: yumuşak akor pedi + Pepe'nin havlamaları ve geçiş sesleri. Telifsiz, burada sentezlenir.
import math, random, struct, wave
SR, DUR = 44100, 57.0
N = int(SR * DUR)
L = [0.0] * N; R = [0.0] * N
def add(i, l, r):
    if 0 <= i < N: L[i] += l; R[i] += r
def note(f): return 440 * 2 ** ((f - 69) / 12)
# Akorlar (MIDI): Fmaj9, Am7, Dm9, Bbmaj7 — her biri 4 sn, döngü.
chords = [[53, 60, 64, 67, 72], [57, 64, 67, 72, 76], [50, 57, 62, 65, 69], [46, 53, 57, 62, 65]]
step = 4.0
for ci in range(int(DUR / step) + 1):
    t0 = ci * step
    for j, m in enumerate(chords[ci % 4]):
        f = note(m); pan = 0.3 + 0.4 * (j / 4)
        a0, a1 = int(t0 * SR), min(N, int((t0 + step + 1.2) * SR))
        for i in range(a0, a1):
            t = (i - a0) / SR
            env = min(1, t / 0.9) * (1 if t < step else max(0, 1 - (t - step) / 1.2))
            v = 0.022 * env * (math.sin(2 * math.pi * f * t) + 0.3 * math.sin(2 * math.pi * f * 2.003 * t)) * (0.85 + 0.15 * math.sin(2 * math.pi * 0.4 * t + j))
            add(i, v * (1 - pan), v * pan)
# Hafif nabız: sekizlik "pluck" arpej
arp = [72, 76, 79, 84, 79, 76]
for k in range(int((DUR - 3) / 0.25)):
    t0 = 3.4 + k * 0.25
    if t0 > DUR - 3.5: break
    ch = chords[int(t0 / step) % 4]
    m = ch[(k % 4) + 1] + 12
    f = note(m); a0 = int(t0 * SR)
    for i in range(a0, min(N, a0 + int(0.4 * SR))):
        t = (i - a0) / SR
        v = 0.018 * math.exp(-t * 9) * math.sin(2 * math.pi * f * t)
        add(i, v * 0.6, v * 0.4)
def chirp(t0, f0=3200, f1=5200, d=0.07, amp=0.12):
    a0 = int(t0 * SR); ph = 0
    for i in range(a0, a0 + int(d * SR)):
        t = (i - a0) / SR; k = t / d
        f = f0 + (f1 - f0) * math.sin(math.pi * k)
        ph += 2 * math.pi * f / SR
        v = amp * math.sin(math.pi * k) ** 2 * math.sin(ph)
        add(i, v, v)
def pop(t0, f=520, amp=0.16):
    a0 = int(t0 * SR); ph = 0
    for i in range(a0, a0 + int(0.18 * SR)):
        t = (i - a0) / SR; ph += 2 * math.pi * (f * (1 + 1.2 * math.exp(-t * 30))) / SR
        v = amp * math.exp(-t * 22) * math.sin(ph); add(i, v, v)
def click(t0):
    a0 = int(t0 * SR); random.seed(3)
    for i in range(a0, a0 + int(0.02 * SR)):
        t = (i - a0) / SR; v = 0.2 * math.exp(-t * 400) * (random.random() * 2 - 1); add(i, v, v)
def bark(t0, f=520, amp=0.22):
    # Kısa, sevimli bir "hav": hızlı yükselip düşen, harmonikli ve biraz gürültülü.
    a0 = int(t0 * SR); ph = 0; d = 0.14; rnd = random.Random(7)
    for i in range(a0, a0 + int(d * SR)):
        t = (i - a0) / SR; k = t / d
        fr = f * (1 + 0.7 * math.sin(math.pi * min(1, k * 1.6)))
        ph += 2 * math.pi * fr / SR
        env = min(1, k * 25) * (1 - k) ** 1.5
        v = env * (0.6 * math.sin(ph) + 0.3 * math.sin(2 * ph) + 0.15 * math.sin(3 * ph) + 0.12 * (rnd.random() * 2 - 1))
        add(i, amp * v, amp * v)
bark(1.25); bark(3.6, 560); bark(3.82, 600)
for t in (6.8, 10.6, 14.4, 18.6, 22.2, 25.8, 29.6, 33.4, 38.0, 42.0, 45.8, 49.4): pop(t)
for t in (34.6, 35.7, 36.8, 47.5): pop(t, 760, 0.08)
chirp(38.6); chirp(40.0, 2600, 4200)
click(17.1); bark(17.3, 600, 0.12)
bark(26.3, 560, 0.16); bark(26.52, 620, 0.16)
bark(54.6, 560); bark(54.82, 620)
# Son 2 sn yumuşak kısma
for i in range(int((DUR - 2) * SR), N):
    g = (N - i) / (2 * SR); L[i] *= g; R[i] *= g
peak = max(max(abs(x) for x in L), max(abs(x) for x in R))
g = 0.85 / peak
with wave.open('muzik.wav', 'w') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(b''.join(struct.pack('<hh', int(L[i] * g * 32767), int(R[i] * g * 32767)) for i in range(N)))
print('ok')
