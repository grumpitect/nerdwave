"""Generates Nerdwave's app icon: a synthwave sun and grid with a quote written along a wave.

Usage:  python3 Tools/make_icon.py Resources                       writes AppIcon.icns and AppIcon-1024.png
        python3 Tools/make_icon.py --png docs/nerdwave-icon.png 2048   one PNG at any size (the README uses 2048)
Needs:  pip install pillow numpy   (macOS: uses the Menlo font and iconutil)
"""
import sys,os,math,shutil,subprocess
import numpy as np
from PIL import Image,ImageDraw,ImageFilter
PNG=sys.argv[2] if len(sys.argv)>2 and sys.argv[1]=="--png" else None
R=None if PNG else (sys.argv[1] if len(sys.argv)>1 else "Resources")
N=int(sys.argv[3]) if PNG and len(sys.argv)>3 else 1024; SS=2; M=N*SS
K=N/1024          # pixel sizes below are tuned for 1024 and scale with the output
I=lambda v:int(round(v))
y=np.mgrid[0:M,0:M][0].astype(np.float32)
hz=I(M*0.60)
t=np.clip(y/hz,0,1)[...,None]
sky=np.array([20,10,60],np.float32)*(1-t)+np.array([200,40,140],np.float32)*t
img=Image.fromarray(np.clip(sky,0,255).astype(np.uint8)).convert("RGBA"); d=ImageDraw.Draw(img)
d.rectangle([0,hz,M,M],fill=(16,6,40,255))
cx,cy,r=M//2,I(hz-M*0.02),I(M*0.24)
sun=Image.new("RGBA",(M,M),(0,0,0,0)); sd=ImageDraw.Draw(sun)
for yy in range(cy-r,cy+1):
    tt=(yy-(cy-r))/r; half=I(math.sqrt(max(0,r*r-(yy-cy)**2)))
    sd.line([(cx-half,yy),(cx+half,yy)],fill=(255,I(230-120*tt),I(90+40*tt),255))
for k in range(6):
    yy=I(cy-r*0.55+k*r*0.11); h=I((4*SS+k*2.2*SS)*K); sd.rectangle([cx-r,yy,cx+r,yy+h],fill=(0,0,0,0))
img=Image.alpha_composite(img,sun.filter(ImageFilter.GaussianBlur(40*SS*K))); img=Image.alpha_composite(img,sun)
g=Image.new("RGBA",(M,M),(0,0,0,0)); gd=ImageDraw.Draw(g)
for i in range(-14,15): gd.line([(cx,hz),(I(cx+i*M*0.11),M)],fill=(90,230,255,170),width=I(3*SS*K))
for k in range(1,12):
    yy=hz+I((M-hz)*((k/11)**2.1)); gd.line([(0,yy),(M,yy)],fill=(255,80,200,150),width=I(3*SS*K))
img=Image.alpha_composite(img,g.filter(ImageFilter.GaussianBlur(3*SS*K))); img=Image.alpha_composite(img,g)
from PIL import ImageFont
w=Image.new("RGBA",(M,M),(0,0,0,0)); wd=ImageDraw.Draw(w)
glyphs=list("{}</>;=()[]λ&|+*#$%~")
seq="{ < / > ; = ( ) [ ] λ & | + * } { < > ; = ( ) [ ]".split()
def wave(u):
    env=math.sin(math.pi*u)**0.8
    return hz-M*0.03+math.sin(u*math.pi*8)*M*0.08*env
# sample the curve densely, then place glyphs at equal arc-length steps so the wave shape reads clearly
us=[i/4000 for i in range(4001)]
pts=[(M*0.08+u*M*0.84, wave(u)) for u in us]
cum=[0.0]
for (x0,y0),(x1,y1) in zip(pts,pts[1:]): cum.append(cum[-1]+math.hypot(x1-x0,y1-y0))
quote="Music is the pleasure the human mind experiences from counting without being aware that it is counting."
count=len(quote); step=cum[-1]/(count-1); j=0
fsize=I(min(M*0.045, step*1.5))
font=ImageFont.truetype("/System/Library/Fonts/Menlo.ttc",fsize,index=1)   # Menlo Bold
for k,ch in enumerate(quote):
    if ch==" ": continue
    target=k*step
    while j<len(cum)-1 and cum[j]<target: j+=1
    xx,yy=pts[j]
    x0,y0=pts[max(0,j-8)]; x1,y1=pts[min(len(pts)-1,j+8)]
    ang=math.degrees(math.atan2(y1-y0,x1-x0))
    tile=Image.new("RGBA",(fsize*2,fsize*2),(0,0,0,0))
    ImageDraw.Draw(tile).text((fsize,fsize),ch,font=font,fill=(255,255,255,255),anchor="mm")
    tile=tile.rotate(-ang,resample=Image.BICUBIC,expand=False)
    w.alpha_composite(tile,(I(xx-fsize),I(yy-fsize)))
arr=np.asarray(w.filter(ImageFilter.GaussianBlur(14*SS*K))).astype(np.float32); arr[...,0]*=0.45; arr[...,1]*=0.95
gl=Image.fromarray(np.clip(arr,0,255).astype(np.uint8))
img=Image.alpha_composite(Image.alpha_composite(img,gl),gl); img=Image.alpha_composite(img,w)
img=img.resize((N,N),Image.LANCZOS)
pad=I(100*K); rad=I(185*K)
mask=Image.new("L",(N,N),0); ImageDraw.Draw(mask).rounded_rectangle([pad,pad,N-pad,N-pad],radius=rad,fill=255)
canvas=Image.new("RGBA",(N,N),(0,0,0,0)); canvas.paste(img.resize((N-2*pad,N-2*pad),Image.LANCZOS),(pad,pad))
out=Image.new("RGBA",(N,N),(0,0,0,0)); out.paste(canvas,(0,0),mask)
sh=Image.new("RGBA",(N,N),(0,0,0,0)); ImageDraw.Draw(sh).rounded_rectangle([pad,pad+I(14*K),N-pad,N-pad+I(14*K)],radius=rad,fill=(0,0,0,110))
final=Image.alpha_composite(sh.filter(ImageFilter.GaussianBlur(16*K)),out)
if PNG: final.save(PNG); print("png ok"); sys.exit(0)
import tempfile
iconset=os.path.join(tempfile.mkdtemp(),"AppIcon.iconset"); os.makedirs(iconset)
for s in (16,32,64,128,256,512):
    final.resize((s,s),Image.LANCZOS).save(f"{iconset}/icon_{s}x{s}.png"); final.resize((s*2,s*2),Image.LANCZOS).save(f"{iconset}/icon_{s}x{s}@2x.png")
subprocess.run(["iconutil","-c","icns",iconset,"-o",os.path.join(R,"AppIcon.icns")],check=True)
final.save(os.path.join(R,"AppIcon-1024.png")); print("icon ok")
