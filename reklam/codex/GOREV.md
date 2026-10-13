# Görev: Pepe için 30 saniyelik tanıtım videosu

Sen bu videonun yönetmeni, tasarımcısı ve kurgucususun. Pepe adlı macOS uygulaması için **kendi yorumunla**, izleyeni ilk 2 saniyede yakalayan, 30 saniyelik bir tanıtım videosu üret.

## Ürün
Pepe, MacBook'un çentiğinde (notch) yaşayan bir yardımcı. Kodlama ajanlarını (Claude Code, Codex, Gemini CLI, Cursor) izler:
- Oturumların adım adım ne yaptığını gösterir (okunan dosyalar, komutlar, satır satır değişiklikler).
- Ajan izin isteyince çentikte kart açılır; terminali aramadan "İzin ver" denir. Soru sorarsa seçenekler çentikte.
- İş bitince Pepe (çizim bir köpek yavrusu) havlar.
- Terminal kapalıyken bile oturuma çentikten yazılır; yeni oturum terminalsiz başlatılır; birden fazla ajan paralel, ayrı çalışma kopyalarında çalışır.
- Bir oturumdaki hatayı başka bir ajana aktarır (Claude'un bulduğu hatayı Codex'e düzelttirmek gibi).
- Pepe'yle sohbet: hatırlatıcı, tekrarlayan otomasyon kurar; saati gelince çentikten dürter. Sabah brifingi hazırlar.
- Stripe, GitHub, Vercel, Cal.com gibi servisler çentikte "pill" olarak.
- "OK Pepe" diyerek sesle soru sorulur.

## Malzeme (bu klasörün bir üstünde, `reklam/`)
- `assets/*.png`: uygulamanın gerçek ekran görüntüleri ve Pepe çizimleri (pepe.png, pepe-mutlu.png, pepe-uyku.png, kıyafetli hâlleri). Önemli olanlar: 2-izin, r-adimlar, r-oturuma-yaz, r-oturuma-yaz-2, 3-ana-bitti, 7-ajanlar, r-sohbet-oturum, r-sohbet-hatirlat, r-sohbet-otomasyon, r-hatirlatma, 8-pill-*, k-kisisel, 12-ses-dinliyor, r-ses-konusuyor, 9-soru-coklu, k-diff. Görsellere bakarak hangisinin ne gösterdiğini kendin anla.
- `fonts/`: Playfair Display ve Montserrat (marka kimliği).
- `render.mjs`: HTML sahnesini kare kare çekip ffmpeg'e veren betik. HTML'nin `window.seek(t)` ve `window.DURATION` tanımlaması gerekir. Kullanım (reklam/ içinden): `HTML=codex/reklam-codex.html node render.mjs` → `video.mp4` üretir; `HTML=... node render.mjs 3.5 10` → `onizleme-3.5.png` gibi önizleme kareleri.
- `reklam-20.html`, `reklam-30.html`, `muzik-kisa.py`: daha önce yapılmış sürümler. Bakabilirsin ama **kopyalama**; kendi kurgu fikrini, kendi tempo ve geçişlerini, kendi metinlerini kur. Farklı bir yaklaşım daha değerli.

## Kurallar
- 1920×1080, 30 fps, tam 30 saniye. Bütün metinler Türkçe, kısa ve okunur (her başlık ekranda en az ~1.5 sn).
- Gerçek ekran görüntülerini kullan; uydurma arayüz çizme.
- Müzik telifsiz olmalı: Python ile kendin sentezle (numpy yok, saf Python). Havlama sesi de sentez olsun. Ses ile görüntü (havlama anları, geçişler) senkron olsun.
- Uygulamanın adı Pepe; gerçek bir köpekle ilgili hikâye, fotoğraf, tarih **kullanma**. Yalnızca çizim karakter ve ürün.
- Kapanışta: PEPE, kısa bir slogan, "Erken erişim · hi@tahayerdekalmazer.com".
- **Yalnızca `reklam/codex/` içine yaz.** Başka hiçbir dosyayı değiştirme ya da silme. render.mjs'in reklam/ içine bıraktığı `video.mp4` ve `onizleme-*.png` dosyalarını codex/ içine taşı ya da sil.

## Teslim (hepsi `reklam/codex/` içinde)
1. `reklam-codex.html` — sahneler.
2. `muzik-codex.py` ve ürettiği `muzik-codex.wav`.
3. `pepe-reklam-codex.mp4` — ses ve görüntü birleşik (ffmpeg ile; ses AAC, `-movflags +faststart`).
4. Kalite kontrolü: en az 8 önizleme karesi al ve **bak**; taşan metin, üst üste binen öğe, boş kalan kare varsa düzelt.
5. `NOTLAR.md` — kurgu fikrin, sahne listesi (saniye · ne görünüyor · metin) ve neyi neden böyle yaptığın; 15 satırı geçmesin.
