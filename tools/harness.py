"""Unattended Co-Driver Coach test run against BeamNG's local MCP server.
Backs up the coach's settings/history, runs drive scenarios and edge cases until the
deadline, restores everything, and writes results.jsonl + screenshots list."""
import datetime, json, os, shutil, sys, tempfile, time, urllib.request

sys.stdout.reconfigure(encoding="utf-8")
URL = "http://127.0.0.1:29292/mcp"
OUT = os.path.join(tempfile.gettempdir(), "cdc_tests")
USER = os.environ.get("BEAMNG_USER") or os.path.join(os.environ.get("LOCALAPPDATA", ""), "BeamNG", "BeamNG.drive", "current")
LOG = os.path.join(USER, "beamng.log")
DEADLINE = datetime.datetime(2026, 10, 17, 19, 40)
FILES = ["coDriverCoach.json", "coDriverCoach_history.json", "coDriverCoach_cars.json"]
RESULTS = os.path.join(OUT, "results.jsonl")
_id = 0


def call(tool, args=None, timeout=90):
    global _id
    _id += 1
    body = json.dumps({"jsonrpc": "2.0", "id": _id, "method": "tools/call", "params": {"name": tool, "arguments": args or {}}}).encode()
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            res = json.loads(r.read().decode("utf-8", "replace"))
    except Exception as e:
        return f"CALL FAILED: {e}"
    if "error" in res:
        return f"RPC ERROR: {res['error']}"
    return "\n".join(c.get("text", "") for c in res["result"].get("content", []) if c.get("type") == "text")


def lua(code, timeout=60):
    return call("run_lua", {"code": code}, timeout)


def lua_json(code):
    out = lua(code)
    try:
        return json.loads(out)
    except Exception:
        return {"raw": out}


def record(rec):
    rec["at"] = datetime.datetime.now().strftime("%H:%M:%S")
    with open(RESULTS, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print(json.dumps(rec, ensure_ascii=False)[:600], flush=True)


def left():
    return (DEADLINE - datetime.datetime.now()).total_seconds()


def log_pos():
    return os.path.getsize(LOG)


def errors_since(pos):
    with open(LOG, "r", encoding="utf-8", errors="replace") as f:
        f.seek(pos)
        text = f.read()
    errs = []
    for line in text.splitlines():
        if "|E|" in line and "dragBridge" not in line:
            errs.append(line[:300])
        elif "coDriverCoach" in line and ("error" in line.lower() or "failed" in line.lower()):
            errs.append(line[:300])
    # CEF errors print a stack on following lines; keep the ones pointing at our apps
    for line in text.splitlines():
        if "CoDriver" in line and "app.js" in line:
            errs.append("  at " + line.strip()[:200])
    return errs[:30]


SNAP = r"""
local s = coDriverCoach.getDebugState()
local n1 = s.notes[1]
return jsonEncode({ kmh = math.floor(s.speed * 3.6), onRoad = s.onRoad, route = s.usingRoute, offRoad = s.offRoad,
  notes = #s.notes, first = n1 and (n1.text .. ' @' .. math.floor(n1.dist)) or nil, brake = s.brake.state, hint = s.hint,
  pathLen = s.path and s.path.length, grip = s.gripG, brakeG = s.brakeG,
  drive = s.drive and { t = math.floor(s.drive.time), km = math.floor(s.drive.dist) / 1000, corners = s.drive.corners,
    cues = s.drive.brakeCues, slides = s.drive.oversteer + s.drive.bigSlide + s.drive.understeer, crashes = s.drive.crashes,
    resets = s.drive.resets, jerk = math.floor(s.drive.meanJerk * 10) / 10, harsh = s.drive.harsh } or nil })
"""


def wait_level(name, timeout=240):
    t0 = time.time()
    while time.time() - t0 < timeout:
        st = call("get_status", timeout=20)
        if name.lower() in st.lower() and '"vehicleCount":0' not in st:
            time.sleep(5)
            return True
        time.sleep(4)
    return False


def load(name, model, config=None):
    pos = log_pos()
    t0 = time.time()
    call("load_level", {"name": name}, timeout=200)
    ok = wait_level(name)
    if model:
        args = {"model": model}
        if config:
            args["config"] = config
        call("spawn", args, timeout=120)
        time.sleep(6)
    call("set_camera", {"name": "orbit"})
    loaded = lua("return tostring(extensions.isExtensionLoaded('coDriverCoach'))")
    record({"test": f"load {name} {model or ''}", "ok": ok, "coachLoaded": loaded, "secs": round(time.time() - t0),
            "vehicle": call("get_vehicle")[:200], "errors": errors_since(pos)})
    return ok


def wait_summary(timeout=45):
    t0 = time.time()
    while time.time() - t0 < timeout:
        s = lua_json("return jsonEncode(coDriverCoach.getSummary() or {none = true})")
        if not s.get("none"):
            return s
        time.sleep(3)
    return None


def drive(label, seconds, aggression=0.7, setup=None, ai=True):
    if left() < seconds + 60:
        record({"test": label, "skipped": "out of time"})
        return
    pos = log_pos()
    lua("coDriverCoach.dismissSummary() return 'ok'")
    call("reset_vehicle")
    time.sleep(3)
    if setup:
        setup()
    elif ai:
        call("set_ai", {"mode": "span", "aggression": aggression, "avoidCars": "off"})
    samples, shots = [], []
    t0 = time.time()
    while time.time() - t0 < seconds:
        time.sleep(10)
        samples.append(lua_json(SNAP))
        if len(samples) == max(2, int(seconds / 20)):
            shots.append(call("screenshot"))
    calls = lua_json("local s = coDriverCoach.getDebugState() local out = {} for i, c in ipairs(s.calls) do out[i] = c.text end return jsonEncode(out)")
    call("set_ai", {"mode": "stop"})
    summary = wait_summary(50)
    shots.append(call("screenshot"))
    call("set_ai", {"mode": "disabled"})
    on = [s for s in samples if s.get("onRoad")]
    record({
        "test": label, "samples": len(samples),
        "onRoadPct": round(100 * len(on) / max(len(samples), 1)),
        "routePct": round(100 * len([s for s in samples if s.get("route")]) / max(len(samples), 1)),
        "maxKmh": max([s.get("kmh", 0) for s in samples] or [0]),
        "lastDrive": (samples[-1].get("drive") if samples else None),
        "grip": samples[-1].get("grip") if samples else None,
        "brakeStates": sorted(set(s.get("brake") for s in samples if s.get("brake"))),
        "hints": sorted(set(s.get("hint") for s in samples if s.get("hint"))),
        "calls": calls, "summary": summary, "screenshots": shots, "errors": errors_since(pos),
        "trace": samples,
    })


def edge_cases():
    if left() < 300:
        record({"test": "edge cases", "skipped": "out of time"})
        return
    pos = log_pos()
    res = {}
    # manual end with no real drive -> friendly "too short" message
    lua("coDriverCoach.dismissSummary() return 'ok'")
    call("reset_vehicle")
    time.sleep(2)
    lua("coDriverCoach.endDrive() return 'ok'")
    res["manualEndShort"] = lua_json("return jsonEncode(coDriverCoach.getSummary() or {})")
    lua("coDriverCoach.dismissSummary() return 'ok'")
    # reset in the middle of a drive should count a reset and keep the drive going
    call("set_ai", {"mode": "span", "aggression": 0.6, "avoidCars": "off"})
    time.sleep(35)
    call("reset_vehicle")
    time.sleep(3)
    call("set_ai", {"mode": "span", "aggression": 0.6, "avoidCars": "off"})
    time.sleep(25)
    res["afterReset"] = lua_json(SNAP).get("drive")
    call("set_ai", {"mode": "disabled"})
    # toggles round-trip
    before = lua_json("return jsonEncode(coDriverCoach.getDebugState().cfg)")
    for cmd in ["toggle()", "toggle()", "toggleVoice()", "toggleVoice()", "toggleStyle()", "toggleStyle()",
                "cycleSurface()", "cycleSurface()", "cycleSurface()"]:
        lua(f"coDriverCoach.{cmd} return 'ok'")
        time.sleep(0.5)
    after = lua_json("return jsonEncode(coDriverCoach.getDebugState().cfg)")
    res["togglesRestored"] = before == after
    # voicepack cycling: every pack should load clips; cycle back to the original
    original = before.get("voicepack")
    packs = []
    for _ in range(6):
        lua("coDriverCoach.cycleVoicepack() return 'ok'")
        time.sleep(1.5)
        st = lua_json("local s = coDriverCoach.getDebugState() return jsonEncode({vp = s.voicepack, clips = s.clipCount})")
        packs.append(st)
        if st.get("vp") == original:
            break
    res["voicepacks"] = packs
    # vehicle switch mid-drive: add a second car, the coach should follow the new player car
    call("set_ai", {"mode": "span", "aggression": 0.6, "avoidCars": "off"})
    time.sleep(20)
    first = lua("return tostring(be:getPlayerVehicleID(0))")
    call("spawn", {"model": "covet", "add": True}, timeout=120)
    time.sleep(8)
    second = lua("return tostring(be:getPlayerVehicleID(0))")
    res["switch"] = {"from": first, "to": second, "coach": lua_json(SNAP)}
    call("remove_vehicle")
    time.sleep(4)
    call("set_ai", {"mode": "disabled"})
    res["afterRemove"] = lua_json(SNAP)
    res["errors"] = errors_since(pos)
    record({"test": "edge cases", **res})


def perf():
    if left() < 120:
        record({"test": "performance", "skipped": "out of time"})
        return
    pos = log_pos()
    call("reset_vehicle")
    time.sleep(2)
    call("set_ai", {"mode": "span", "aggression": 0.6, "avoidCars": "off"})
    time.sleep(10)
    out = {}
    for state in ["on", "off", "on2"]:
        lua("coDriverCoach.setEnabled(%s) return 'ok'" % ("false" if state == "off" else "true"))
        time.sleep(3)
        frames = []
        for _ in range(15):
            frames.append(call("get_performance_metrics")[:1500])
            time.sleep(1)
        out[state] = frames
    lua("coDriverCoach.setEnabled(true) return 'ok'")
    # direct cost of the coach's own work, timed inside the game
    out["luaCost"] = lua(r"""
local t0 = os.clock()
for i = 1, 50 do coDriverCoach.getView() end
local view = (os.clock() - t0) / 50 * 1000
return string.format('getView %.3f ms per call', view)
""")
    call("set_ai", {"mode": "disabled"})
    out["errors"] = errors_since(pos)
    record({"test": "performance", **out})


def gps_route():
    def setup():
        target = lua_json(r"""
local veh = getPlayerVehicle(0)
local p = vec3(veh:getPosition())
local best, bestD
for id, n in pairs(map.getMap().nodes) do
  local d = (n.pos - p):length()
  if d > 900 and d < 1500 and (not bestD or math.abs(d - 1200) < math.abs(bestD - 1200)) then best, bestD = n.pos, d end
end
if not best then return jsonEncode({none = true}) end
local ok, err = pcall(core_groundMarkers.setPath, vec3(best))
return jsonEncode({x = best.x, y = best.y, z = best.z, d = bestD, setPath = ok, err = tostring(err)})
""")
        record({"test": "gps target", "target": target})
        if "x" in target:
            call("drive_to", {"pos": {"x": target["x"], "y": target["y"], "z": target["z"]}, "aggression": 0.6, "avoidCars": "off"})
    drive("GPS route (west_coast_usa etk800)", 150, setup=setup)
    lua("pcall(core_groundMarkers.setPath, nil) return 'ok'")


def backup():
    os.makedirs(os.path.join(OUT, "backup"), exist_ok=True)
    for f in FILES:
        src = os.path.join(USER, "settings", f)
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(OUT, "backup", f))
    record({"test": "backup", "files": os.listdir(os.path.join(OUT, "backup"))})


def restore():
    pos = log_pos()
    call("set_ai", {"mode": "disabled"})
    load("italy", "vivace", "ardente_track")
    call("set_ai", {"mode": "disabled"})
    for f in FILES:
        b = os.path.join(OUT, "backup", f)
        dst = os.path.join(USER, "settings", f)
        if os.path.exists(b):
            shutil.copy2(b, dst)
        elif os.path.exists(dst):
            os.remove(dst)  # did not exist before the tests
    # reload the coach so it picks up the restored settings, history and learned grip
    lua('extensions.unload("coDriverCoach") setExtensionUnloadMode("coDriverCoach","manual") extensions.load("coDriverCoach") return "ok"')
    time.sleep(3)
    lua("coDriverCoach.dismissSummary() return 'ok'")
    call("set_camera", {"name": "orbit"})
    record({"test": "restore", "cfg": lua_json("return jsonEncode(coDriverCoach.getDebugState().cfg)"),
            "learned": lua_json("return jsonEncode(coDriverCoach.getDebugState().learned)"), "errors": errors_since(pos)})


def main():
    open(RESULTS, "w").close()
    backup()
    try:
        call("set_camera", {"name": "orbit"})
        drive("Italy vivace track, aggressive", 240, aggression=0.75)
        edge_cases()
        perf()
        if left() > 900 and load("west_coast_usa", "etk800"):
            drive("West Coast etk800, moderate", 210, aggression=0.6)
            gps_route()
        if left() > 600 and load("Utah", "pickup"):
            drive("Utah pickup, moderate", 200, aggression=0.6)
        if left() > 420 and load("johnson_valley", "pickup"):
            drive("Johnson Valley pickup (off-road)", 150, aggression=0.5)
    except Exception as e:
        record({"test": "harness crashed", "error": repr(e)})
    finally:
        restore()
        record({"test": "done"})


if __name__ == "__main__":
    main()
