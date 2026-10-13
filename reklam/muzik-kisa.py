# Kısa tanıtımların müziği: 120 bpm; önce gerilim, DROP'ta düşüş (Pepe çentikten fırlar), END'de kapanış akoru.
# Havlamalar uygulamadaki sentezle aynı (SoundEngine.swift → Synth.barks). Telifsiz, burada sentezlenir.
# Kullanım: python3 muzik-kisa.py 20|30|45  → muzik-<n>.wav (reklam-<n>.html ile aynı zamanlar)
import math, random, struct, sys, wave
SR, BEAT = 44100, 0.5
# barks: (sn, perde) · clicks: imlecin tıkladığı anlar · chimes: hatırlatma zili
CUTS = {
    '20': dict(dur=20.0, drop=4.0, end=16.0, barks=[(4.08, 430), (11.0, 430), (11.22, 480), (17.0, 470)],
               clicks=[7.1], chimes=[]),
    '30': dict(dur=30.0, drop=3.0, end=27.0, barks=[(3.08, 430), (12.5, 430), (12.72, 480), (28.0, 470)],
               clicks=[6.15, 10.15], chimes=[20.15]),
    '45': dict(dur=45.0, drop=4.0, end=40.0, barks=[(4.08, 430), (17.2, 430), (17.42, 480), (41.0, 470)],
               clicks=[8.4, 14.75], chimes=[28.15]),
}
NAME = sys.argv[1] if len(sys.argv) > 1 else '20'
CUT = CUTS[NAME]
DUR, DROP, END = CUT['dur'], CUT['drop'], CUT['end']
N = int(SR * DUR)
music = [[0.0] * N, [0.0] * N]   # kick geldikçe kısılır (sidechain)
drums = [[0.0] * N, [0.0] * N]
fx = [[0.0] * N, [0.0] * N]
rnd = random.Random(3)
def hz(m): return 440 * 2 ** ((m - 69) / 12)
def put(bus, i, v, pan=0.5):
    if 0 <= i < N: bus[0][i] += v * (1 - pan); bus[1][i] += v * pan

def pluck(t0, m, amp, pan=0.5, dec=7.0, dur=0.6, bright=0.5):
    # Testere dalgası + tek kutuplu alçak geçiren; parlaklık zamanla söner.
    f = hz(m); a0 = int(t0 * SR); ph = 0.0; y = 0.0
    for i in range(int(dur * SR)):
        t = i / SR
        ph = (ph + f / SR) % 1
        cut = 0.04 + bright * math.exp(-t * 9)
        y += cut * ((2 * ph - 1) - y)
        put(music, a0 + i, amp * y * min(1, t / 0.003) * math.exp(-t * dec), pan)

def pad(t0, notes, dur, amp):
    # Hafif akortsuz iki testere, yavaş giriş-çıkış.
    a0 = int(t0 * SR)
    for k, m in enumerate(notes):
        for det, pan in ((-0.06, 0.25), (0.06, 0.75)):
            f = hz(m) * 2 ** (det / 12); ph = 0.0; y = 0.0
            for i in range(int(dur * SR)):
                t = i / SR
                ph = (ph + f / SR) % 1
                y += 0.05 * ((2 * ph - 1) - y)
                env = min(1, t / 0.8) * min(1, (dur - t) / 0.6)
                put(music, a0 + i, amp * y * env / len(notes), pan)

def bass(t0, m, dur, amp):
    f = hz(m); a0 = int(t0 * SR); ph = 0.0
    for i in range(int(dur * SR)):
        t = i / SR
        ph += 2 * math.pi * f / SR
        v = math.sin(ph) + 0.3 * math.sin(2 * ph)
        put(music, a0 + i, amp * v * min(1, t / 0.005) * math.exp(-t * 3), 0.5)

def kick(t0, amp=0.6):
    a0 = int(t0 * SR); ph = 0.0
    for i in range(int(0.35 * SR)):
        t = i / SR
        ph += 2 * math.pi * (45 + 110 * math.exp(-t * 28)) / SR
        put(drums, a0 + i, amp * math.sin(ph) * math.exp(-t * 9), 0.5)

def noise_hit(t0, dur, amp, dec, hp=True, pan=0.5):
    a0 = int(t0 * SR); lo = 0.0
    for i in range(int(dur * SR)):
        t = i / SR; n = rnd.random() * 2 - 1
        lo += 0.15 * (n - lo)
        put(drums, a0 + i, amp * (n - lo if hp else lo * 2.5) * math.exp(-t * dec), pan)

def clap(t0, amp=0.32):
    for d in (0, 0.011, 0.023):
        noise_hit(t0 + d, 0.2, amp, 22 if d else 30, hp=True)

def bark(t0, pitch, amp=1.0, dur=0.17):
    # Synth.barks'ın Python hâli: testere + nefes → üç formant süzgeci, "vu-AF-f".
    a0 = int(t0 * SR); n = int(dur * SR); ph = 0.0
    st = [[0.0] * 4 for _ in range(3)]
    out = []
    for i in range(n):
        p = i / n
        contour = 0.8 + 0.4 * (p / 0.2) if p < 0.2 else 1.2 - 0.55 * ((p - 0.2) / 0.8)
        f0 = pitch * contour * (1 + 0.03 * (rnd.random() * 2 - 1))
        ph = (ph + f0 / SR) % 1
        breath = 0.25 + 0.35 * abs(p - 0.35)
        src = (2 * ph - 1) * (1 - breath) + (rnd.random() * 2 - 1) * breath
        op = math.sin(min(1, p * 1.6) * math.pi)
        v = 0.0
        for k, (f, q, g) in enumerate(((300 + 550 * op, 6, 1), (900 + 500 * op, 7, .7), (2500 + 300 * op, 9, .3))):
            w = 2 * math.pi * f / SR; al = math.sin(w) / (2 * q)
            x1, x2, y1, y2 = st[k]
            y = (al * src - al * x2 + 2 * math.cos(w) * y1 - (1 - al) * y2) / (1 + al)
            st[k] = [src, x1, y, y1]
            v += y * g
        v += math.sin(ph * 2 * math.pi) * 0.25 * (1 - p)
        out.append(v * min(1, p * 25) * (1 - p) ** 1.3)
    peak = max(abs(x) for x in out) or 1
    for i, v in enumerate(out):
        put(fx, a0 + i, amp * v / peak, 0.55)

# Akorlar ölçü başına (2 sn = 4 vuruş): F · C · Dm · Bb ...
F, C, Dm, Bb = (41, [65, 69, 72, 76]), (36, [64, 67, 72, 74]), (38, [65, 69, 72, 74]), (34, [65, 70, 74, 77])
bars = [[F, C, Dm, Bb][b % 4] for b in range(int((END - DROP) / 2))]

# Giriş: pad + giderek açılan pluck + tik tik hihat + yükselen gürültü
steps = int(DROP / 0.25)
pad(0, [53, 57, 60, 64], DROP + 0.1, 0.26)
for s in range(steps):
    t = s * 0.25
    pluck(t, F[1][[0, 2, 1, 3][s % 4]], 0.12 + 0.12 * t / DROP, 0.3 + 0.4 * (s % 2), bright=0.15 + 0.3 * t / DROP)
    noise_hit(t, 0.05, 0.1 + 0.12 * s / steps, 60, pan=0.6)
a0 = int((DROP - 1.4) * SR)
for i in range(int(1.35 * SR)):                # yükseliş
    t = i / SR; n = rnd.random() * 2 - 1
    put(fx, a0 + i, 0.22 * n * (t / 1.35) ** 2, 0.5)

# Düşüş: ölçü başına bir akor (2 sn = bir sahne)
for b, (root, notes) in enumerate(bars):
    t0 = DROP + b * 2
    pad(t0, [m - 12 for m in notes], 2.05, 0.07)
    for beat in range(4):
        t = t0 + beat * BEAT
        kick(t)
        if beat % 2: clap(t)
        noise_hit(t + 0.25, 0.12, 0.09, 30, pan=0.62)
        for e in (0, 0.25):
            bass(t + e, root + (12 if e else 0), 0.24, 0.32)
    for s in range(16):                         # 16'lık arpej
        m = notes[[0, 1, 2, 3, 2, 1, 3, 2][s % 8]] + (12 if s in (6, 14) else 0)
        pluck(t0 + s * 0.125, m, 0.075, 0.25 if s % 2 else 0.75, dec=9, dur=0.35)
        noise_hit(t0 + s * 0.125, 0.03, 0.025, 90, pan=0.4)

# Kick sidechain: müzik her vuruşta nefes alır.
for b in range(len(bars) * 4):
    a0 = int((DROP + b * BEAT) * SR)
    for i in range(int(BEAT * SR)):
        if a0 + i < N:
            g = 1 - 0.6 * math.exp(-i / SR * 14)
            music[0][a0 + i] *= g; music[1][a0 + i] *= g

# Kapanış: davul yok, uzun akor ve son havlama
kick(END, 0.7)
pad(END, [53, 60, 65, 69, 72, 79], DUR - END, 0.4)
bass(END, 29, DUR - END - 0.5, 0.45)
for j, m in enumerate([65, 69, 72, 76, 79, 84]):
    pluck(END + j * 0.125, m, 0.14, 0.3 + 0.08 * j, dec=2.5, dur=3, bright=0.35)

def tone(t0, f, dur, amp, pan=0.5):
    a0 = int(t0 * SR)
    for i in range(int(dur * SR)):
        t = i / SR
        put(fx, a0 + i, amp * math.sin(2 * math.pi * f * t) * min(1, t / 0.004) * math.exp(-t * 7), pan)

for t, pitch in CUT['barks']:
    bark(t, pitch)
for t in CUT['clicks']:                         # imlecin tıklaması
    noise_hit(t, 0.02, 0.35, 220, pan=0.55); tone(t, 2400, 0.03, 0.12)
for t in CUT['chimes']:                         # hatırlatma: uygulamadaki "İzin isteği" zili
    tone(t, 880, 0.3, 0.3); tone(t + 0.12, 1320, 0.4, 0.3)

L = [music[0][i] + drums[0][i] + fx[0][i] for i in range(N)]
R = [music[1][i] + drums[1][i] + fx[1][i] for i in range(N)]
# Basit oda yankısı
for d, g in [(0.083, .16), (0.131, .11), (0.197, .07)]:
    o = int(d * SR)
    for i in range(N - 1, o - 1, -1):
        L[i] += g * R[i - o]; R[i] += g * L[i - o]
for i in range(int((DUR - 1.4) * SR), N):
    g = (N - i) / (1.4 * SR); L[i] *= g; R[i] *= g
# Yumuşak sınırlayıcı
peak = max(max(abs(x) for x in L), max(abs(x) for x in R))
sat = lambda x: math.tanh(1.6 * x / peak) / math.tanh(1.6)
with wave.open(f'muzik-{NAME}.wav', 'w') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(b''.join(struct.pack('<hh', int(sat(L[i]) * 0.89 * 32767), int(sat(R[i]) * 0.89 * 32767)) for i in range(N)))
print('ok')
