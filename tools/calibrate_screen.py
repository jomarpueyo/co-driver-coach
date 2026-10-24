"""Measure where the car's navigation screen sits in the driver view and find the tilt that shows it.

Floods the screen with a marker colour, screenshots the driver camera at a few tilts,
finds the marker, converts pixel rows to angles, and reports the smallest tilt that
keeps the whole screen inside the view (with a margin)."""
import json, math, os, subprocess, sys, time
from PIL import Image

BMCP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bmcp.py")


def call(*args):
    return subprocess.run([sys.executable, "-I", BMCP, *args], capture_output=True, text=True, encoding="utf-8").stdout.strip()


def lua(code):
    return call("run_lua", code)


MARKER_ON = """local veh = getPlayerVehicle(0) for _, m in ipairs(coDriverCoach.getDebugState().screens or {}) do
veh:queueJSUITexture(m, "(function(){var d=document.getElementById('__cdcMarker'); if(!d){d=document.createElement('div'); d.id='__cdcMarker'; document.body.appendChild(d);} d.style.cssText='position:fixed;left:0;top:0;width:100%;height:100%;background:#ff00ff;z-index:2147483647;';})()") end return 'on'"""
MARKER_OFF = """local veh = getPlayerVehicle(0) for _, m in ipairs(coDriverCoach.getDebugState().screens or {}) do
veh:queueJSUITexture(m, "(function(){var d=document.getElementById('__cdcMarker'); if(d) d.remove();})()") end return 'off'"""


def set_tilt(t):
    return lua(f"local cams = core_camera.getCameraDataById(be:getPlayerVehicleID(0)) cams.driver.seatRotation = {t} return 'tilt ' .. tostring(cams.driver.seatRotation)")


def marker_rows(path):
    img = Image.open(path).convert("RGB")
    w, h = img.size
    px = img.load()
    rows, cols = [], []
    for y in range(0, h, 2):
        for x in range(0, w, 4):
            r, g, b = px[x, y]
            if r > 170 and b > 170 and g < 110:
                rows.append(y)
                cols.append(x)
    if len(rows) < 30:
        return None, (w, h)
    return (min(rows), max(rows), min(cols), max(cols), len(rows)), (w, h)


def row_to_angle(y, h, fov):
    """Angle above (+) or below (-) the view centre for an image row (vertical FOV)."""
    yc = (h - 1) / 2
    return math.degrees(math.atan((yc - y) / yc * math.tan(math.radians(fov / 2))))


def main():
    fov = float(lua("return tostring(core_camera.getFovDeg())"))
    original = lua("local cams = core_camera.getCameraDataById(be:getPlayerVehicleID(0)) return tostring(cams.driver.seatRotation)")
    print("fov", fov, "original tilt", original)
    lua(MARKER_ON)
    results = {}
    try:
        for t in (0, -6, -12):
            set_tilt(t)
            time.sleep(1.2)
            shot = call("screenshot").strip()
            time.sleep(0.8)
            box, (w, h) = marker_rows(shot)
            if box:
                top, bottom = row_to_angle(box[0], h, fov), row_to_angle(box[1], h, fov)
                cut = box[1] >= h - 4
                results[t] = {"top": round(top, 2), "bottom": round(bottom, 2), "cut_at_bottom": cut, "x": [box[2], box[3]]}
            else:
                results[t] = None
            print("tilt", t, "->", results[t], flush=True)
    finally:
        lua(MARKER_OFF)
        set_tilt(original)
    # with the camera tilted by t, the screen's true angles (relative to the untilted view) shift by t;
    # use a reading where the screen is fully visible to get its true extent
    full = [(t, r) for t, r in results.items() if r and not r["cut_at_bottom"]]
    if not full:
        print("screen never fully visible; try larger tilts")
        return
    t, r = full[0]
    sign = 1
    # work out the tilt direction from how the marker moved between tilts
    if results.get(0) and results.get(-6):
        sign = 1 if results[-6]["top"] < results[0]["top"] else -1
    true_top = r["top"] - sign * t
    true_bottom = r["bottom"] - sign * t
    need = (-fov / 2 + 1.5) - true_bottom   # bring the bottom 1.5 deg inside the view edge
    tilt = max(0.0, need) * sign
    print(json.dumps({"fov": fov, "screen_top_deg": round(true_top, 2), "screen_bottom_deg": round(true_bottom, 2),
                      "tilt_needed": round(tilt, 1), "direction_sign": sign}))


if __name__ == "__main__":
    main()
