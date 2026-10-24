#!/usr/bin/env bash
# Repeatable frame-time benchmark: the AI drives a fixed route (waypoints from a recorded session)
# from the same start, with a fixed free camera (constant rendering) or the driver camera.
# Usage: tools/perf_bench.sh <session.json> <rounds> <secs> <cam: fixed|driver> "<label>=<lua setup>" ...
#   e.g. tools/perf_bench.sh settings/coDriverCoach/sessions/X.json 3 25 fixed \
#          "replay off=coDriverAnalysis.setOption('recordReplay','off')" \
#          "replay always=coDriverAnalysis.setOption('recordReplay','always')"
# Configurations alternate within each round, so slow drift affects all of them equally.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
MOD="$LOCALAPPDATA/BeamNG/BeamNG.drive/current/mods/unpacked/co_driver_coach/lua/ge/extensions"
B() { python -I "$HERE/bmcp.py" run_lua "$1"; }
SESSION="$1"; ROUNDS="$2"; SECS="$3"; CAM="$4"; shift 4
cp "$HERE/bench/cdcBench.lua" "$MOD/cdcBench.lua"
B 'extensions.unload("cdcBench") extensions.load("cdcBench") return "loaded"' >/dev/null
echo "route waypoints: $(B "return cdcBench.setRouteFromSession('$SESSION', 2.0, 200)")"
B 'cdcBench.clear() return "ok"' >/dev/null
for r in $(seq 1 "$ROUNDS"); do
  for cfg in "$@"; do
    label="${cfg%%=*}"; setup="${cfg#*=}"
    B "$setup return 'set'" >/dev/null
    B "return cdcBench.run('$label r$r', $SECS, '$CAM', 5)" >/dev/null
    for i in $(seq 1 $((SECS + 30))); do sleep 1; [ "$(B 'return tostring(cdcBench.busy())')" = "false" ] && break; done
  done
done
B 'local o = {} for _, r in ipairs(cdcBench.results()) do o[#o+1] = string.format("%-26s fps %6.1f  avg %5.2f  p50 %5.2f  p95 %5.2f  p99 %5.2f  max %6.1f  >20ms %3d  >25ms %3d  end %4.1f m/s", r.label, r.fps or 0, r.avgMs or 0, r.p50 or 0, r.p95 or 0, r.p99 or 0, r.max or 0, r.over20 or 0, r.over25 or 0, r.speed or 0) end return table.concat(o, "\n")'
B 'extensions.unload("cdcBench") return "unloaded"' >/dev/null
rm -f "$MOD/cdcBench.lua"
