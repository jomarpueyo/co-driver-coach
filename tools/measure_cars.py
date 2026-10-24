"""Swap in each config, measure its navigation screen in the driver view, report the screen's
bottom edge angle (degrees below the eye line at zero tilt) and the view's response per degree of tilt."""
import json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import calibrate_screen as cs

CONFIGS = sys.argv[1:] or ["vivace:ardente_S_310_DCT", "vivace:vivace_S_310_DCT"]


def wait_screens(timeout=20):
    t0 = time.time()
    while time.time() - t0 < timeout:
        out = cs.lua("return jsonEncode(coDriverCoach.getDebugState().screens or {})")
        try:
            lst = json.loads(out)
            if lst:
                return lst
        except Exception:
            pass
        time.sleep(1)
    return []


def reading(t, fov):
    cs.set_tilt(t)
    time.sleep(1.3)
    shot = cs.call("screenshot").strip()
    time.sleep(0.8)
    box, (w, h) = cs.marker_rows(shot)
    if not box:
        return None
    return {"top": cs.row_to_angle(box[0], h, fov), "bottom": cs.row_to_angle(box[1], h, fov),
            "cut": box[1] >= h - 4 or box[0] <= 3, "x": [box[2], box[3]], "shot": shot}


results = {}
for spec in CONFIGS:
    model, config = spec.split(":")
    print(f"== {model} {config}", flush=True)
    print("  spawn:", cs.call("spawn", json.dumps({"model": model, "config": config}))[:80], flush=True)
    time.sleep(6)
    cs.call("set_camera", json.dumps({"name": "driver"}))
    screens = wait_screens()
    print("  screens:", screens, flush=True)
    if not screens:
        results[spec] = {"error": "no navigation screen found"}
        continue
    time.sleep(2)
    fov = float(cs.lua("return tostring(core_camera.getFovDeg())"))
    cs.lua(cs.MARKER_ON)
    time.sleep(0.6)
    reads = {}
    try:
        for t in (0, -6, -12):
            reads[t] = reading(t, fov)
            r = reads[t]
            print(f"  tilt {t}: " + (f"top {r['top']:.2f}  bottom {r['bottom']:.2f}  cut={r['cut']}  x={r['x']}" if r else "marker not found"), flush=True)
    finally:
        cs.lua(cs.MARKER_OFF)
    full = [t for t in (-6, -12) if reads.get(t) and not reads[t]["cut"]]
    if len(full) == 2:
        k = (reads[-12]["bottom"] - reads[-6]["bottom"]) / 6
        b0 = reads[-6]["bottom"] - 6 * k
        results[spec] = {"bottom": round(b0, 2), "response": round(k, 3),
                         "height": round(reads[-6]["top"] - reads[-6]["bottom"], 2), "fov": fov}
    else:
        results[spec] = {"error": "screen not fully visible at -6/-12", "reads": {str(k): v for k, v in reads.items()}}
    print("  result:", results[spec], flush=True)

print("RESULTS " + json.dumps(results))
