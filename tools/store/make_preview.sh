#!/bin/bash
# App Store preview (886x1920, 30 fps, silent AAC) from the simulator recording made by record.sh.
# Usage: make_preview.sh <dir with rec.mov> ; renders captions from video/*.html first.
# Caption windows come from the scene times record.sh logged in scenes.txt (each held 4 s).
set -e
V=$(cd "$1" && pwd); HERE=$(cd "$(dirname "$0")" && pwd)
CH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
cp "$HERE/../icon/icon.svg" "$V/icon.svg"
for k in c1 c2 c3 c4 c5; do
  "$CH" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 --virtual-time-budget=5000 \
    --window-size=886,1920 --screenshot="$V/$k.png" "file://$HERE/video/$k.html" >/dev/null 2>&1
done
cp "$HERE/video/outro.html" "$V/outro.html"
"$CH" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files --virtual-time-budget=5000 \
  --window-size=886,1920 --screenshot="$V/outro.png" "file://$V/outro.html" >/dev/null 2>&1
cd "$V"
# Trim before the first scene; caption i from just before scene i to just before scene i+1;
# end 2.5 s into the last scene, then the 2 s outro.
read -r SS END W1 W2 W3 W4 W5 <<<"$(python3 - scenes.txt <<'PY'
import sys
t = [float(l.split()[1]) for l in open(sys.argv[1]) if l.strip()]
assert len(t) == 5, f"expected 5 scenes, got {len(t)}"
ss = max(0.0, t[0] - 2.2); t = [x - ss for x in t]; end = t[4] + 2.5
w = [(0.0 if i == 0 else t[i] - 0.8, (t[i + 1] - 1.2) if i < 4 else end) for i in range(5)]
print(f"{ss:.2f} {end:.2f}", *[f"{a:.2f},{b:.2f}" for a, b in w])
PY
)"
TOTAL=$(python3 -c "print(round($END + 2, 2))")
ffmpeg -v error -y -ss "$SS" -t "$END" -i rec.mov -loop 1 -t 2 -i outro.png -i c1.png -i c2.png -i c3.png -i c4.png -i c5.png \
  -f lavfi -t "$TOTAL" -i anullsrc=channel_layout=stereo:sample_rate=44100 -filter_complex "
[0:v]fps=30,scale=886:-2,crop=886:1920:0:(ih-1920)/2,setsar=1[f];
[f][2:v]overlay=enable='between(t,$W1)':format=auto[a];
[a][3:v]overlay=enable='between(t,$W2)'[b];
[b][4:v]overlay=enable='between(t,$W3)'[c];
[c][5:v]overlay=enable='between(t,$W4)'[d];
[d][6:v]overlay=enable='between(t,$W5)'[e];
[1:v]fps=30,scale=886:1920,setsar=1[o];
[e][o]concat=n=2:v=1:a=0,format=yuv420p[v]" -map "[v]" -map 7:a -c:v libx264 -profile:v high -level 4.0 \
  -b:v 10M -maxrate 12M -bufsize 20M -c:a aac -b:a 256k -shortest -movflags +faststart preview-886x1920.mp4
echo "$V/preview-886x1920.mp4"
