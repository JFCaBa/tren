# Style B store screenshots: departure-board panel above the app in dark mode.
import os, subprocess, sys
sp = os.path.abspath(sys.argv[1])  # file:// URLs need an absolute path
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SCENES = [  # file, left, right, caption, status-bar bg
    ("01-proximo", "board",    "C-7 PRÍNCIPE PÍO", "AHORA", ["¿CUÁNTO FALTA", "PARA TU TREN?"], "rgb(14,21,20)"),
    ("02-via",     "platform", "C-4b COLMENAR",    "VÍA 2", ["LA VÍA, ANTES DE", "LLEGAR AL ANDÉN"], "rgb(14,21,20)"),
    ("03-retrasos","filter",   "C-2 CHAMARTÍN",    "+5'",   ["RETRASOS Y", "CANCELACIONES"], "rgb(14,21,20)"),
    ("04-paradas", "stops",    "PRÍNCIPE PÍO",     "09:09", ["TODAS LAS PARADAS", "QUE LE QUEDAN"], "rgb(14,21,20)"),
    ("05-buscar",  "search",   "BUSCAR: SOL",      "2 KM",  ["CUALQUIER ESTACIÓN", "DE CERCANÍAS"], "rgb(6,10,9)"),
]
SETS = {"ios-6.9": (1320, 2868, True), "ios-6.3": (1206, 2622, True), "android": (1080, 2400, False)}
FONTS = '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Doto:wght@700;900&family=Roboto:wght@500&display=block">'

def page(scene, H, ios):
    name, shot, left, right, cap, sbg = scene
    statusbar = "" if ios else f'''<div class="sb" style="background:{sbg}"><span>8:13</span>
      <svg width="150" height="40" viewBox="0 0 150 40"><path d="M10 30 L34 6 L34 30Z" fill="#fff"/><path d="M50 14a26 26 0 0 1 36 0l-18 18z" fill="#fff"/>
      <rect x="100" y="8" width="20" height="26" rx="4" fill="#fff"/><rect x="106" y="4" width="8" height="4" fill="#fff"/></svg></div>'''
    island = '<div class="island"></div>' if ios else ''
    return f'''<!doctype html><meta charset=utf-8>{FONTS}<style>
html,body{{margin:0;width:1206px;height:{H}px;overflow:hidden;background:#0A0E12}}
body{{position:relative;font-family:'Doto',monospace}}
.board{{position:absolute;left:64px;right:64px;top:110px;border-radius:30px;background:#11161b;
  box-shadow:inset 0 0 0 4px #1d242b, 0 30px 80px -30px #000;padding:54px 56px 58px;display:grid;gap:30px}}
.row{{display:flex;justify-content:space-between;gap:24px;color:#FFB020;font-weight:900;font-size:66px;line-height:1;
  text-shadow:0 0 18px rgba(255,176,32,.55);white-space:nowrap}}
.rule{{height:4px;background:repeating-linear-gradient(90deg,#2a323a 0 10px,transparent 10px 20px)}}
.cap{{color:#E8F4F1;font-weight:900;font-size:84px;line-height:1.08;text-shadow:0 0 16px rgba(127,209,199,.45)}}
.glow{{position:absolute;left:0;right:0;top:{H*0.33:.0f}px;height:{H*0.45:.0f}px;background:radial-gradient(closest-side,rgba(255,176,32,.13),transparent)}}
.phone{{position:absolute;left:150px;width:906px;top:660px;border-radius:124px;background:#05080a;padding:24px;
  box-shadow:0 0 0 3px #2a3138, 0 80px 140px -40px rgba(0,0,0,.9)}}
.screen{{position:relative;border-radius:100px;overflow:hidden}}
.screen img{{display:block;width:100%}}
.island{{position:absolute;left:50%;top:26px;width:240px;height:70px;margin-left:-120px;border-radius:40px;background:#000}}
.sb{{position:absolute;left:0;right:0;top:0;height:150px;display:flex;justify-content:space-between;align-items:center;
  padding:30px 70px 0;box-sizing:border-box;color:#fff;font:500 40px Roboto,sans-serif}}
</style><body>
<div class=board><div class=row><span>{left}</span><span>{right}</span></div><div class=rule></div>
<div class=cap>{cap[0]}<br>{cap[1]}</div></div>
<div class=glow></div>
<div class=phone><div class=screen><img src="file://{sp}/raw/{shot}.png">{statusbar}{island}</div></div></body>'''

for setname, (W, Hout, ios) in SETS.items():
    H = round(1206 * Hout / W)
    out = f"{sp}/final/{setname}"; os.makedirs(out, exist_ok=True)
    for sc in SCENES:
        html = f"{out}/{sc[0]}.html"
        open(html, "w").write(page(sc, H, ios))
        png = f"{out}/{sc[0]}.raw.png"
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
            "--virtual-time-budget=6000", f"--force-device-scale-factor={W/1206}", f"--window-size=1206,{H}",
            f"--screenshot={png}", f"file://{html}"], capture_output=True)
        subprocess.run(["magick", png, "-resize", f"{W}x{Hout}!", "-alpha", "remove", "-alpha", "off", f"PNG24:{out}/{sc[0]}.png"])
        os.remove(png); os.remove(html)
    print(setname, W, Hout)
