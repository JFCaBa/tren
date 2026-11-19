#!/bin/bash
# start recording when the test starts; log scene offsets; stop at the end
LOG=$1; OUT=$(mkdir -p "$2" && cd "$2" && pwd); U=$3  # test log, output dir, simulator UDID
tail -n +1 -F "$LOG" 2>/dev/null | while read -r line; do
  case "$line" in
    *"store screens"*) if [ -z "$PID" ]; then xcrun simctl io $U recordVideo --codec h264 --force "$OUT/rec.mov" >/dev/null 2>&1 & PID=$!; sleep 1; kill -0 $PID 2>/dev/null || { echo "recordVideo failed"; exit 1; }; T0=$(python3 -c 'import time;print(time.time())'); echo "rec $PID"; fi;;
    *"SCENE "*) n=${line##*SCENE }; n=${n%%[^a-z]*}; python3 -c "import time;print('$n', round(time.time()-$T0,2))" >> "$OUT/scenes.txt";;
    *"All tests passed"*|*"tests failed"*) sleep 0.5; kill -INT $PID; sleep 3; echo "end"; pkill -f "tail -n +1 -F $LOG"; exit 0;;
  esac
done
