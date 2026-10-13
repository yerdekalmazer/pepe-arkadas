#!/usr/bin/env python3
"""HTML sahnelerinin Chromium gerektirmeyen yerel video çizimi.
python3 codex/render-codex.py [--preview | --render]
Pillow yalnızca görsel dizgi için kullanılır; müzik standart Python ile üretilir.
"""
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont,ImageFilter
from functools import lru_cache
import subprocess,math,sys,json
BASE=Path(__file__).resolve().parent
ROOT=BASE.parent
W,H=1920,1080
FPS=30
STARTS=[0,3,6,9,12,15,18,21,24]
BG=['#252721','#f2eee5','#f7c86f','#f2eee5','#d65c41','#252721','#f2eee5','#dce6e8','#f2eee5']
INK=['#f5f0e4','#23241f','#23241f','#23241f','#fff5e6','#f5f0e4','#23241f','#23241f','#23241f']
ACC=['#ff7958','#c64931','#895226','#c64931','#ffe0a5','#ffc86a','#c64931','#32646e','#cb4d35']
META=[
 ('Mac’inin çentiğinde bir yardımcı.',['Ajanın','ne yapıyor?'],1,'Bir bakış. Her şey gözünün önünde.','Claude Code · Codex · Gemini CLI · Cursor'),
 ('01 / Takip et',['Her adımı','gör.'],1,'Dosyalar. Komutlar.\nSatır satır değişiklikler.','Ajanın çalışırken sen de ne yaptığını bil.'),
 ('02 / Karar ver',['İzin mi','lazım?','Bir dokunuş.'],2,'Terminali aramadan.\nDoğrudan çentikten.','Kontrol sende. Akış devam etsin.'),
 ('03 / Devam et',['Terminal','kapalı.','Sohbet açık.'],2,'Oturumuna çentikten yaz.\nKaldığın yerden devam et.','Bir sonraki adım, tek mesaj uzağında.'),
 ('04 / Birlikte çalış',['Birden','fazla ajan.','Tek çentik.'],2,'Paralel oturumlar.\nHepsi aynı yerde.','Claude Code · Codex · Gemini CLI · Cursor'),
 ('05 / Haberin olsun',['İş bitti mi?','Pepe ses verir.'],1,'','Sen işine odaklan. Pepe haber versin.'),
 ('06 / Aklında tutma',['Söyle.','Hatırlatsın.'],1,'Hatırlatıcılar ve\ntekrarlayan otomasyonlar.','Zamanı gelince, yine çentikte.'),
 ('07 / Seslen',['“OK Pepe”','İşler nasıl?'],0,'Stripe · GitHub\nVercel · Cal.com','Servislerin de çentikte. Cevaplar bir ses uzağında.'),
 ('Mac’inin yeni yardımcısı.',['PEPE'],-1,'','macOS için.')]
SHOTS={1:('r-adimlar.png',756,205,1080),2:('2-izin.png',756,244,1080),3:('r-oturuma-yaz-2.png',756,207,1080),4:('7-ajanlar.png',800,193,1030),5:('3-ana-bitti.png',835,467,975),6:('r-sohbet-otomasyon.png',786,205,1020),7:('8-pill-stripe.png',756,277,1080)}
@lru_cache(None)
def font(size,weight=500,italic=False):
 f=ImageFont.truetype(str(ROOT/'fonts'/('PlayfairItalic.ttf' if italic else 'Montserrat.ttf')),size)
 f.set_variation_by_axes([weight]);return f

def text(im,xy,s,size=27,weight=500,fill='#23241f',italic=False,spacing=0):
 d=ImageDraw.Draw(im);f=font(size,weight,italic);x,y=xy
 if spacing:
  baseline=y-f.getbbox(s,anchor='ls')[1]
  for ch in s:
   d.text((x,baseline),ch,font=f,fill=fill,anchor='ls');x+=d.textlength(ch,font=f)+spacing
 else:d.text((x,y),s,font=f,fill=fill,anchor='lt')

def tracked_width(s,size,weight,spacing=0):return font(size,weight).getlength(s)+spacing*(len(s)-1)
def transparent():return Image.new('RGBA',(W,H))
def ease(x):return 1-(1-max(0,min(1,x)))**3
@lru_cache(None)
def asset(name,width):
 a=Image.open(ROOT/'assets'/name).convert('RGBA');return a.resize((width,round(a.height*width/a.width)),Image.Resampling.LANCZOS)
@lru_cache(None)
def shadowed(name,width):
 a=asset(name,width);p=70
 layer=Image.new('RGBA',(a.width+2*p,a.height+2*p))
 mask=Image.new('L',layer.size);mask.paste(a.getchannel('A'),(p,p+20));mask=mask.filter(ImageFilter.GaussianBlur(22));mask=mask.point(lambda x:int(x*.15))
 layer.paste((0,0,0),mask=mask);layer.alpha_composite(a,(p,p));return layer

def paste(im,a,x,y,alpha=1,scale=1):
 if alpha<=0:return
 if abs(scale-1)>.001:
  ow=a.width;a=a.resize((round(a.width*scale),round(a.height*scale)),Image.Resampling.BICUBIC);x+=(ow-a.width)/2
 if alpha<.999:a=a.copy();a.putalpha(a.getchannel('A').point(lambda p:int(p*alpha)))
 im.alpha_composite(a,(round(x),round(y)))

backgrounds=[];copies=[]
for i in range(9):
 im=Image.new('RGBA',(W,H),BG[i]);d=ImageDraw.Draw(im)
 if i in [0,8]:
  if i==0:d.ellipse((930,30,1980,1080),outline='#42453c',width=1)
  else:d.ellipse((1010,108,1860,958),outline='#ded9cf',width=1)
 text(im,(100,58),'PEPE',32,850,INK[i],spacing=6)
 tr='ERKEN ERİŞİM' if i==8 else 'AKLIN İŞİNDE KALSIN.'
 text(im,(1820-tracked_width(tr,21,600,1.5),62),tr,21,600,INK[i],spacing=1.5)
 text(im,(100,982),META[i][4],20,550,INK[i])
 fol=f'{i+1:02} / 09';text(im,(1820-tracked_width(fol,20,600,2),982),fol,20,600,INK[i],spacing=2)
 d.line((100,1037,1820,1037),fill=('#51534a' if i in [0,5] else '#aaa79c'),width=2)
 backgrounds.append(im)
 cp=transparent();y=265 if i==0 else 211 if i==5 else 208 if i==8 else 296 if i==7 else 292 if i==6 else 294
 label=META[i][0].replace('i','İ').replace('ı','I').upper()
 text(cp,(100,y),label,21,700,INK[i],spacing=3)
 y+=57;size=150 if i==0 else 112 if i==5 else 220 if i==8 else 94
 lh=size*(1.03 if i==0 else 1 if i==8 else 1.08)
 for j,line in enumerate(META[i][1]):
  emph=j==META[i][2]
  text(cp,(100,round(y+j*lh)),line,size,500 if emph else 750 if i==8 else 620,ACC[i] if emph else INK[i],emph,-8 if i==0 else -10 if i==8 else -5)
 if META[i][3]:
  yy=y+len(META[i][1])*lh+36
  for j,line in enumerate(META[i][3].split('\n')):text(cp,(100,round(yy+j*44.5)),line,32 if i==0 else 27,500,INK[i])
 if i==8:
  text(cp,(100,519),'Aklın işinde kalsın.',72,500,INK[i],True,-2)
  text(cp,(100,654),'Erken erişim · hi@tahayerdekalmazer.com',29,550,INK[i])
  dd=ImageDraw.Draw(cp);dd.rounded_rectangle((100,734,459,794),radius=30,outline=INK[i],width=1);text(cp,(125,753),'Çentiğinde buluşalım.',21,550,INK[i])
 copies.append(cp)

def frame(t):
 i=max(j for j,st in enumerate(STARTS) if t>=st);local=t-STARTS[i];e=1 if i==0 else ease(local/.56)
 im=backgrounds[i].copy()
 if i in [0,8]:
  d=ImageDraw.Draw(im);cx,cy,rad=(1460,560,325) if i==0 else (1435,534,355);rad*=.85+.15*e;d.ellipse((cx-rad,cy-rad,cx+rad,cy+rad),fill='#ff7958' if i==0 else '#e97555')
 paste(im,copies[i],0,(1-e)*40,.4+.6*e)
 if i in SHOTS:
  name,x,y,w=SHOTS[i];a=shadowed(name,w);paste(im,a,x-70,y-70+(1-e)*75,e,.965+.035*e)
 if i in [0,8]:
  width,x,y=(680,1150,242) if i==0 else (650,1103,214)
  a=asset('pepe.png',width);rot=(1-e)*8
  if rot:a=a.rotate(rot,resample=Image.Resampling.BICUBIC,expand=False)
  paste(im,a,x,y+(1-e)*60+math.sin(local*2.5)*5,.6+.4*e)
 if i==2 and local>.7:
  layer=transparent();d=ImageDraw.Draw(layer);d.rounded_rectangle((1668,748,1788,812),radius=32,outline='#ffce6b',width=4);paste(im,layer,0,0,.55+.4*math.sin(local*6))
 if i==5:
  b=math.exp(-((local-.6)/.1)**2)+math.exp(-((local-.94)/.11)**2)
  a=asset('pepe-mutlu.png',450).rotate(b*5,resample=Image.Resampling.BICUBIC);paste(im,a,200,490-b*26)
  if local>=.57:
   speech=Image.new('RGBA',(220,140));text(speech,(10,15),'Hav!',68,500,ACC[i],True)
   speech=speech.rotate(12,resample=Image.Resampling.BICUBIC,expand=False);paste(im,speech,640,516,scale=1+b*.12)
 if i==6:
  r=ease((local-.65)/.5);paste(im,shadowed('r-hatirlatma.png',1020),716,720+(1-r)*35,r)
 if i==7:
  v=ease((local-.6)/.5);paste(im,asset('r-ses-konusuyor.png',1000),796,730+(1-v)*25,v)
 d=ImageDraw.Draw(im);d.line((100,1037,100+1720*t/30,1037),fill=INK[i],width=3)
 return im.convert('RGB')

def previews():
 times=[0,1.5,4.5,7.5,10.5,13.5,15.65,19.5,22.5,27.5,29.9667]
 for t in times:frame(t).save(BASE/f'onizleme-{t:g}.png')
 sheet=Image.new('RGB',(1440,4*290),'#ddd9d0');d=ImageDraw.Draw(sheet)
 for j,t in enumerate(times):
  thumb=frame(t).resize((480,270),Image.Resampling.LANCZOS);x=(j%3)*480;y=(j//3)*290;sheet.paste(thumb,(x,y));d.text((x+12,y+273),f'{t:.2f} s',fill='black')
 sheet.save(BASE/'kalite-kontrol.jpg');print('11 önizleme ve kontrol paftası hazır.',flush=True)

def render():
 cmd=['ffmpeg','-y','-hide_banner','-loglevel','warning','-f','rawvideo','-pix_fmt','rgb24','-s','1920x1080','-r','30','-i','-','-i',str(BASE/'muzik-codex.wav'),'-map','0:v','-map','1:a','-c:v','libx264','-crf','17','-preset','medium','-pix_fmt','yuv420p','-c:a','aac','-b:a','256k','-ar','48000','-t','30','-movflags','+faststart',str(BASE/'pepe-reklam-codex.mp4')]
 p=subprocess.Popen(cmd,stdin=subprocess.PIPE)
 try:
  for n in range(900):
   p.stdin.write(frame(n/30).tobytes())
   if n%150==0:print(f'kare {n}/900',flush=True)
 finally:p.stdin.close()
 if p.wait():raise RuntimeError('ffmpeg başarısız')
 print('900 kare + AAC ses tamamlandı.',flush=True)
if __name__=='__main__':
 if '--render' not in sys.argv:previews()
 if '--preview' not in sys.argv:render()
