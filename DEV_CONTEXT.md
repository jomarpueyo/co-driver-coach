# Developer context (read this first when resuming)

Working notes for continuing development of the Co-Driver Coach. Written so a fresh session, or one after context compaction, can carry on without re-discovering anything.

## Project layout
- `co_driver_coach/`: the mod source; deploy copies it into the game.
  - `lua/ge/extensions/coDriverCoach.lua`: the co-driver (calls, voice, grading, debrief, screens), about 2,000 lines; the practice scenarios are in `coDriverCoach/scenarios.lua`. **LuaJIT limit: max 200 locals in the main chunk.** It's at 182; wrap new sections in `do ... end` and expose functions through pre-declared locals (see the screen section and the remark-voice helpers). Count with `node <lint>/count.js`.
  - `lua/ge/extensions/coDriverCoach_screen.js`: the canvas layer injected into in-car navi screens.
  - `lua/ge/extensions/coDriverAnalysis.lua`: post-drive analysis (separate extension, its own local budget):
    - session recorder and rotating `.rpl` replay parts
    - better line, ideal speed profile, corner rules
    - replay playback with 3D lines
  - `lua/vehicle/extensions/coDriverRec.lua`: about 60 Hz telemetry sampler in the vehicle VM (tyre load and surface class included), sends batches to `coDriverAnalysis.onChunk` and the car's mass, power, brakes, drive and ABS to `onCarInfo`. `sendStatus()` sends the car's condition to `coDriverEngineer.onStatus`.
  - `lua/ge/extensions/coDriverEngineer.lua`: the race engineer (bridge client, push-to-talk, car and weather summaries, condition alerts).
  - `lua/ge/extensions/coDriverLaps.lua`: automatic lap and route recognition (loops, point to point, manual marks), lap timing, routes per level.
- `tools/engineer.py` + `engineer.bat`: the local bridge (`engineer_speech.ps1` is the Windows dictation/Zira fallback).
  - faster-whisper `base.en` for speech-to-text (pre-roll, cleaned audio, retry, voice log), Kokoro for the voice.
  - Claude Haiku (`claude-haiku-5-5`) through urllib when a key is set (env var or `tools/.anthropic_key`), rule-based answers otherwise.
  - `lua/ge/extensions/core/input/actions/coDriverCoach.json`: hotkey actions.
  - `lua/ge/extensions/gameplay/rally/compositors/voicepacks/custom/`: where a recorded voicepack goes (120 OGG clips plus `metadata.json`, no `voicepack.json`). Not in this repository: build your own with `tools/voicepack/`.
  - `scripts/co_driver_coach/modScript.lua`: loads the extension (manual unload mode).
  - `ui/modules/apps/{CoDriverCoach,CoDriverMap,CoDriverDebrief,CoDriverScenarios,CoDriverAnalysis}/`: Angular UI apps (`app.js` + `app.json`).
- `tools/`: helper scripts.
  - `deploy.sh`: copies the mod and hot-reloads it over MCP.
  - `bmcp.py`: MCP client. `python -I tools/bmcp.py <tool> '<json>'`, or `run_lua 'code'`, or `run_lua @file.lua`.
  - `voice_review.py` + `voice_review.bat`: the voice log review page (127.0.0.1:8766), corrections -> `voicelog/fixes.json`.
  - `voicepack/`: the 7 numbered steps that built the custom voicepack from the OBS recordings (see its README).
  - Screen calibration: `calibrate_screen.py`, `measure_cars.py`.
  - Test harness: `harness.py`.
  - `offline/`: runs `coDriverAnalysis.lua` in node with fengari and mocked game APIs (saved sessions, a synthetic walled corner). See its README.
- Docs: `README.md` (user-facing), `ROADMAP.md` (status and next work), `VOICE_SCRIPT.md`; `docs/` holds the designs and the project review, `docs/archive/` the first test report and the review brief.
- Set `git config core.longpaths true` (the Windows checkout has long paths).

## Game and environment
- **BeamNG.drive 0.40** (since 2026-10-20; built against 0.39.4 before that) in your Steam library (`steamapps\common\BeamNG.drive`). See "Game 0.40" below. Game Lua is plain text under `lua/`; levels and vehicles are zips under `content/`.
- **User folder:** `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current`. The installed mod is in `mods/unpacked/co_driver_coach`; settings are in `settings/`; the log is `beamng.log`.
- **Game MCP server:** `http://127.0.0.1:29292/mcp` (Options → enable MCP). Useful tools:
  - code: `run_lua`, `run_lua_vehicle` (async; call twice)
  - visuals: `screenshot`, `ui_eval` (JS needs `return`; async, call twice), `ui_click`, `reload_ui`
  - world and vehicles: `spawn`, `set_position`, `get_position`, `set_ai`, `drive_to`, `load_level`, `set_camera {"name":...}`
- **Python:** for audio and image work, a venv with numpy, soundfile, av and pillow (the author keeps one in `%TEMP%\cdcaudio`). Run scripts with `python -I`. Lua lint: `node` + luaparse in `%TEMP%\cdclint` (`c.js` syntax and globals, `count.js` locals).

## Development setup
- Tested with a steering wheel and pedals, on an ultrawide at 3440×1417 with **UI scale 1.5 and UI Max Resolution Unlimited**. The panel sizes and the navi-screen framing were tuned there.
- Driver FOV 36° (wider than the geometric 26.5°); the screen framing works from the FOV, so test both.
- Cars used most: Vivace (track, rally and Ardente trims) and ETK 800.
- **Live tests:** never change the camera, car or level while someone is driving; save and restore the car's pose around AI test drives.

## Game API learnings (verified)
- **Road graph:**
  - `map.getMap().nodes[id].links` stores each edge on **one** node only; use `map.getGraphpath().graph[id]` for neighbours (bidirectional, with `inNode`/`oneWay`/`drivability`).
  - `map.findBestRoad(pos, dir)` and `map.findClosestRoad(pos)`.
  - `map.getPath(a, b, 0.25, 1e4, 1, 1000)`, `map.getPathLen`, `map.getNodesFromPathDist`.
- **GPS route:** `core_groundMarkers.setPath(nodeId|vec3|nil)`, `.routePlanner.path[i].pos`, `.getPathLength()`. After you overshoot a target the route re-plans backwards; ignore routes pointing behind the car.
- **Vehicle VM → GE:** `veh:queueLuaCommand(str)` runs in the vehicle; it calls back with `obj:queueGameEngineLua(str)`. Electrics: `electrics.values.{rpm,maxrpm,gear,throttle,brake,steering_input,gearboxMode,airspeed}`. `sensors.gx2/gy2` are smoothed g (gx2 lateral). `beamstate.damage` is in joules; the game's AI treats over 1000 J as a crash.
- **Cameras:** `core_camera.getCameraDataById(vid).driver` has `.seatRotation` (negative looks down; the view moves about 0.835° per degree), `.seatPosition` (nil until the camera initialises), and `.saveTimeout = 0` to persist. Getters: `core_camera.getFovDeg/getPosition/getQuat/getActiveCamName(0)`.
- **Audio:**
  - `Engine.Audio.playOnce('AudioGui', file, {volume=v})` returns `{sourceId, len}`. That's the plain output.
  - `Engine.Audio.intercomPlayPacenote({filename})` is the rally intercom.
  - `getAudioStats().cpuDsp` sits around 100% in this game (game-side; it's the "static").
- **UI:**
  - Angular apps still work (`app.json` with `directive`/`domElement` + `app.js`). Events come from `guihooks.trigger(name, data)`; the app listens with `scope.$on(name)`. JS calls Lua with `bngApi.engineLua(code)`.
  - Empty Lua tables arrive as `{}` (not `[]`); guard with `Array.isArray`.
  - The layout engine converts placements to **em** and rejects `calc()`/`min()`; use px. `margin:auto` + left/right 0 centres. Edit layouts with `ui_appLayouts.addApp/applyPlacementPatch(filename, index0, placement)`.
  - Hidden overlay apps still catch clicks: set `pointer-events: none` on their ancestors up to `.overlay-item` while hidden.
  - `--ui-scale` CSS variable plus `zoom: var(--ui-scale)` keeps the coach panels sharp.
- **In-car screens:** `veh:queueJSUITexture(material, jsCode)` runs JS in a vehicle HTML texture. Navi screens come from the `beamNavigator` controller (`v.data.controller[].screenMaterialName`).
- **Levels:** `freeroam_freeroam.startFreeroamByName(level, spawnPoint)`. Spawn objects: `scenetree.findObject(name)`, then `spawn.safeTeleport(veh, pos, quat(rot)*quat(0,0,1,0))`. Replace a car with `core_vehicles.replaceVehicle(model, {config='vehicles/m/c.pc'})`. Hooks: `onClientPostStartMission`, `onVehicleResetted`, `onVehicleSwitched`.
- **Settings:** `settings.getValue/setValue` (e.g. `cameraDriverFov`, `cameraDriverVehicleConfigs` as a JSON string, `uiUpscaling`, `uiContentScale`).

## How the coach works (short)
- **10 Hz pipeline:** road ahead (GPS route if valid, else graph walk), then resample every 4 m, then curvature over a ±3-sample window, then corners graded 1–6 / hairpin / square by effective radius (`R + 1.5/(1-cos(θ/2))`), plus crests, jumps and dips. The target speed is `sqrt(grip·g·Reff)`. Grip and braking are learned per car config and surface (they only rise).
- **Calls and brake cues:** a call is made when the corner is within `speed·callAheadSec`, linked by "and"/"into" when close, with an optional distance prefix. Brake cues escalate brake → brake now → brake hard. The voice queue gives corner calls priority over chatter (`say(words, urgent, chat)`).
- **Drive review:**
  - Corners are tracked to get minimum speed vs target and incidents.
  - Brake cues are judged by how the corner turned out.
  - Smoothness uses jerk from `sensors.gx2/gy2` in 1 s buckets, skipping crash windows.
  - Seven aspects are graded A+ to F, with an overall grade, a path to the next grade, and focus plus mindset.
  - History is kept in `settings/coDriverCoach_history.json`.
- **Scenarios:** 12 presets (map, spawn point, car, surface) plus GPS stages of 2/4/6 km with countdown and finish detection.

## Drive analysis (built 2026-10-18)
- Design and methods: `docs/ANALYSIS_DESIGN.md`.
- Flow: a session starts after 1 s moving with the coach on. The debrief offers Keep recording / Review analysis. `coDriverAnalysis.review()` ends the session, saves it, analyses it and opens the panel.
- **Verified live:**
  - Replay offset (replay clock minus telemetry clock) is about 0.02 s. Analysis of 1.4 km takes 0.03 s.
  - `core_replay.loadFile(fn, true)`, then `seek`, `pause` and `stop` all work. After `stop()`, `spawn.safeTeleport` restores the car.
  - `.rpl` is about 57 MB/min.
- **The CoDriverAnalysis app must use `position: fixed`:** the layout engine gives a top/left/right/bottom placement a 0×0 overlay item.
- Console:
  - `coDriverAnalysis.open()`, `loadLast()`, `review()`
  - `replayCorner(id)`, `replayAt(t)`, `exitReplay()`
  - `getResult()`, `getRecording()`
- Test without driving: let the AI drive (`ai.setMode("span")`), stop it, then `coDriverCoach.endDrive()` and click Review. Save and restore the car's pose.

## Race engineer (built 2026-10-18)
- **Game ↔ bridge** talk through JSON files in `settings/coDriverCoach/engineer/`:
  - The game writes `tmp_*` and renames it to `req_<time>_<n>.json`. The bridge answers with `res_<id>.json`.
  - The bridge heartbeat `bridge.json` (`t` in unix seconds) counts as online when under 5 s old.
  - Windows locks a file while the game reads it, so bridge writes retry.
- **Request types:** `listen`, `stop` (returns `text`), `ask` (`question`, `mode` drive/review, `data`, `speak`), `say`, `quiet`.
- **Car data units:**
  - tyre temperatures from `obj:getWheelAvgTemperature` are in **Kelvin**; brake and engine temperatures are in °C
  - tyre pressure is absolute Pa (subtract 101325 for gauge)
  - `brakeThermalEfficiency` is also low on **cold** brakes, so fade only counts above 300 °C
- **Weather:** `core_environment.getState()` gives `time` (0 = noon), `temperatureC`, `cloudCover`, `fogDensity`, `windSpeed` and `numOfDrops` (rain). `core_weather` presets exist; nothing changes the weather on its own.
- **Deploy** reloads the vehicle-side `coDriverRec` too (vehicle extensions don't reload on `extensions.load`).

## Engineer car adjustments (2026-10-19)
- **What:** by voice mid-drive: brake bias, brake strength, force feedback, and the car's electronics (drive mode, ESC, TC, ABS, two-step launch, AWD centre lock). Nothing is written to config, tuning or bindings. "Same car, same settings": they persist through resets for this car and session, and clear on session end or car change (the author's requirement).
- **Flow:**
  - Bridge (`engineer.py`): Haiku tools `set_brake_bias`, `set_brake_strength`, `set_ffb_strength`, `set_drive_mode`, `set_driver_aids`, `set_launch_control`, `set_awd_lock`, `revert_adjustments`, with thinking disabled. Without Haiku (or when it fails), `offline_adjust` phrase matching.
  - The `ask` answer carries `actions`: `[{kind, value}]`. Kinds: bias / brake / ffb / awdLock in points or percent, launchRPM in rpm, esc / tc / abs / launch as booleans, driveMode as a key, `'stock'` to clear one, or `{kind = 'revert'}`. Drive mode only.
  - GE `coDriverEngineer.applyActions` forwards them to `coDriverRec.adjust{...}` (fractions) or `revert`.
  - The vehicle reports through `onAdjust(id, info, 'queued'|'applied'|'kept'|'restored'|'reverted', reason)`. `sendStatus` carries `adjust`: targets, `now` (what the electronics run), `has`, `driveModes` and `launchMaxRPM`.
- **Vehicle side (`coDriverRec.lua`):**
  - Clamps: bias ±0.10, brake 0.8–1.1, FFB 0.6–1.3, awdLock 0–0.6, launchRPM 1500 to 90% of the engine's max RPM (`LIMITS`). The bridge mirrors these in `ADJ_LIMITS`. Anything the car lacks is dropped.
  - Queues until |steering_input| < 0.08 and brake input < 0.02 for 0.4 s.
  - Brakes: `brakeTorque = initialBrakeTorque * brake * (front ? f/f0 : (1-f)/(1-f0))`.
  - FFB: `hydros.wheelFFBForceCoef` and `wheelFFBForceCoefLowSpeed`, smoothstep over 1 s.
  - Electronics: `driveModes.setDriveMode`; `yawControl` / `tractionControl` `setParameters{isEnabled}`; `electronicSplitShaftLock` `setParameters{minimumLock}`; `twoStepLaunch` `setParameters{isEnabled, launchRPM}`; `wheels.setABSBehavior('off')` / `resetABSBehavior()`. Clearing one re-applies the drive mode (or `'default'` on cars without modes), then the rest on top. Modes come from the jbeam's `enabledModes*`.
  - State is in `coDriverRecShared.adj`.
  - On a vehicle reset, `onReset` flags `reapply`; the next frame re-applies brakes, FFB and electronics.
  - When the driver picks a drive mode (key differs from `modeSeen`), their choice wins: the electronics overrides are dropped (ABS kept).
- **GE side (`coDriverEngineer.lua`):**
  - `adjStore = {vid, key = carId, targets}`, in memory only, mirrored from the vehicle's reports. `getKeptAdjustments()` shows it.
  - `carId` comes from the vehicle: model, `.pc` file, and a digest of its sorted parts and tuning vars. GE's `veh.partConfig` can't be used: for a custom config it is the serialized parts tree, and its order changes across a reload.
  - **A reload fires `onVehicleSwitched(-1, -1)`, `onVehicleSpawned(id)`, then `onVehicleSwitched(-1, id)`**, and the analysis ends its recording because the car vanished for a moment. So a switch to -1 isn't a car change, and a recording that stops within 3 s of that isn't a session end.
  - After a spawn or switch back to the same id, the GE asks the car for a status. If the car has no set and the same `carId`, it gets `adjust(t, 'restore', true)`; a different `carId` clears the store. Any status showing no targets triggers the same check, at most every 5 s.
  - A switch to a different car clears the store, and the old car is reverted at once. `onClientEndMission` clears it too.
  - Session end: `coDriverAnalysis.isRecording()` goes from true to false, then a queued revert, reported as "session over".
- **Game behaviour this relies on (0.39.4):**
  - ABS (`wheels.lua`, `brakeControl.lua`), ESC and TCS read `wd.brakeTorque` live.
  - The vehicle reset order is: `onReset` hook, then `wheels.reset` (restores `brakeTorque`), …, `hydros.reset` (zeroes the FFB limit; the coefficient is untouched), …, `controller.resetLastStage` (re-applies the drive mode).
  - `CMU.applyParameter` takes dotted keys and `'default'`. The supervisors' `getConfig().isEnabled` gives the live state.
- **Tests:** `tools/offline/t_adjust.lua` (fengari, vehicle and GE together, 58 checks) and `python -I tools/test_engineer_adjust.py` (24 tests, fake API).
- **Live (2026-10-19, Vivace Ardente track, wheel):**
  - Brakes: stock front share 77%. At +2 points and 95%, the front went 3542 → 3452 Nm and the rear 1058 → 918 Nm.
  - FFB 300/30 → 270/27. The undo ramp took 1.00 s over 59 frames, max 0.26% per frame, measured parked with no wheel load.
  - Electronics read back in the car: Sport mode, TC off with ESC on (`getConfig`), centre lock 0.3, launch 4500. ABS off changes the wheels' `updateBrake` function, and undo restores it.
  - A reset (`requestReset`) kept everything (brakes 3634/966 Nm, FFB 270, Sport, TC off, lock 0.3), with the "still set after the reset" message.
  - A reload (`core_vehicle_manager.reloadVehicle(0)`) kept everything once `carId` and the reload hook order were handled. The game itself carries the drive mode across a reload.
  - Undo returned everything to stock and the drive mode to the one before the first change.
- **Haiku with thinking off:**
  - It once said "Copy, launch control set to 4500" without calling the tool. The bridge now asks again once when a clear change request (by the offline phrases) gets no tool call, then falls back to the phrases.
  - It also spoke its reasoning when the rules used meta-words ("a feeling", "in the list"). The rules are now examples, and the radio line always comes from a follow-up call after the tool result (about +0.8 s).
- **Live testing tips:**
  - Vehicle hooks are cached: after wrapping `coDriverRec.updateGFX`, call `extensions.hookUpdate("updateGFX")`.
  - `obj:requestReset(RESET_PHYSICS)` moves the car to its spawn point, so save and restore the pose.
  - Other sessions run their own drives (with manual input, not `ai.mode`): check the car's speed right before each step, not only at the start.
  - Fengari has 32-bit integers: keep hash moduli under 2^31 in code the offline tests run.

## Analysis v2 (2026-10-18)
- About 60 Hz telemetry. Charts draw the full-rate `result.trace`; the model keeps its 4 m grid.
- Better line bounds:
  - road edges from the graph projection, not the smoothed centreline
  - walls from `castRayStatic` rays left and right of your line (two heights, following crossfall)
  - every line step raycast across the car's width
- Car model:
  - aero from tyre load vs speed
  - robust per-corner grip per surface, excluding impacts
  - braking capped by brake torque
  - power curve for acceleration
  - margin (default 95%) and style (auto/rally/circuit)
- Details are in `docs/ANALYSIS_DESIGN.md` section F.
- Session archive: `settings/coDriverCoach/sessions/<stamp>_<level>_<model>.json` plus `index.json` (newest first, the last 20, sessions of 60 s / 500 m and more).
  - `endSession()` saves both last_session.json and the archive. It runs on Review, car switch, coach off, mission end and unload.
  - `loadLast()` archives an older version's last session if missing.
  - `loadSession(name|path)` and `listSessions()`; the panel's **sessions** list uses `requestSessions()` and the `CoDriverAnalysisSessions` event.
  - v1 (main, 20 Hz) files load: samples are cut to 17 fields and string keys repaired.
- `castRayStatic(origin, dir, maxDist)` returns the distance, or maxDist on a miss. The car's reference point sits about 0.35 m above the ground. It costs under 0.01 ms per ray.
- Vehicle VM: `wheels.wheelRotators[i].downForceRaw` (N), `.contactMaterialID1/2` (4 = tyre rubber), `.brakeTorque`, `.radius`, `.isPropulsed`, `.hasABS`. Also `powertrain.getDevicesByCategory('engine')[1].maxPower` (hp) and `obj:calcBeamStats().total_weight` (kg).

## Replay modes and testing notes (2026-10-19)
- **Replay mode:** `coDriverAnalysis.setOption('recordReplay', 'off'|'laps'|'always')` (default laps). `armReplay()` arms the current drive; `coDriverCoach.isStageActive()` is the stage trigger. `setReplayPartSecs(n)` turns on timed rotation, for tests only (0 turns it off).
- **Never delete user recordings or sessions without the author's approval.** The mod no longer prunes anything.
  - Back up `settings/coDriverCoach` and `replays/codriver` before tests (to `Documents/BeamNG_CoDriver_Backups/<stamp>`).
  - Move test files into a quarantine folder instead of deleting them.
- **`spawn.safeTeleport(veh, pos, rot)` turns the rotation by quat(0,0,1,0)**, so the car ends up facing backwards. To restore a car's own pose, use `veh:setPosRot(x, y, z, qx, qy, qz, qw)`, or pass `quat(0,0,-1,0) * rot`.
- **Benchmark:** `bash tools/perf_bench.sh settings/coDriverCoach/sessions/<session>.json <rounds> <secs> fixed|driver "label=<lua setup>" ...` gives a fixed route and alternating configurations. The harness is installed and removed automatically.
- **ui_eval runs its JS twice** (dispatch, then result), so toggling UI by clicking twice cancels out. Use idempotent JS.

## Lap timing (2026-10-19)
- **Design:** `docs/PROJECT_REVIEW.md` §5.1, with these changes: a found loop is confirmed by driving it a second time (lap 2 with 90% of the checkpoints) before it is saved or shown, so re-driving a street doesn't make routes; discovery is `auto` by default (no confirm toast mid-drive); loops are at least 600 m and 30 s; a place passed in the same direction 100-600 m earlier means a smaller loop (roundabout), so no route.
- **Core:** `coDriverLaps.step(dt, x, y, z, vx, vy, vz, fx, fy)` takes plain numbers; `onUpdate` feeds it from the player car with `dtSim`. Offline: `tools/offline/t_laps.lua` (loop, restart with a saved route, reverse, detour, roundabout, out and back, figure 8, helix, point to point with resets, manual marks).
- **Hooks:** `coDriverAnalysis.onLap(lap)` stores laps in the session (times converted with `rec.lapOff`, measured in `onChunk`); `wantReplay()` asks `coDriverLaps.wantsReplay()` (a lap in progress, or heading for a start line within 150 m). The strip listens to `CoDriverLaps`.
- **State for debugging:** `coDriverLaps.getState()`.

## Official courses (Phase C, 2026-10-20)
- **Files** (read through `FS`/`readFile`/`jsonReadFile` from `/levels/<level>/quickrace/`; the level zips hold them):
  - `<track>.json`: `name` (translation key, e.g. `quickrace.west_coast_usa.city_race_1.title` = "Street Course 1"; translated with `_tr`), `closed`, `reversible`, `lapCount`, `lapConfig` (checkpoint names), `finishLineCheckpoint`, `startLineCheckpoint` (open courses; some have neither and start at `<track>_standing_spawn`). Some files have trailing commas; the game's `jsonReadFile` accepts them.
  - Checkpoints are `new BeamNGWaypoint(<name>) { position = "x y z"; scale = "r r r"; ... };` in the Torque prefab text `<track>.prefab`, overridden by `<track>_forward.prefab` / `<track>_reverse.prefab` (positions differ a little per direction). A few write `position = " 800.4 ..."` with a leading space. Spawn points are `new SpawnSphere(<track>_standing_spawn)`. Utah's canyon_race names `ut_wp_4`, which is in no prefab (looked up with `scenetree.findObject`, else skipped).
  - `<track>.race.json` (newer, Industrial, Gridmap v2, Jungle Rock Island, Hirochi crawl): `pathnodes` (`oldId`, `pos`, `radius`), `segments` (`from`, `to` by `oldId`), `startNode`, `endNode`, `startPositions`, `classification` {closed, reversible, branching}. Read when not branching and no `.json` of the same name exists.
  - Order, as in `scenario/quickRaceLoader.lua` and `gameplay/race/path.lua`: closed = finish line, lapConfig..., finish line; reversed = lapConfig reversed, and an open course swaps start and finish. `gameplay/missions/.../timeTrialMissions.lua` builds the time trials from the same files, so there is nothing separate to read there.
  - Layouts per level (courses counting the reverses), from the 0.40 zips: West Coast USA 13 (22), Italy 13 (25), Utah 6 (12), East Coast USA 10 (19), Industrial 18 race.json (35), Automation Test Track 8 (16), Gridmap v2 8 race.json (16), Jungle Rock Island 8 race.json (16), Small Island 6 (12), Hirochi Raceway 6 (11), Derby 2 (3). Driver Training's are procedural and skipped. Only West Coast USA was loaded in game.
- **Code:** `lua/ge/extensions/coDriverLaps/courses.lua` (`list(level)`, `buildLine(course)`), required by `coDriverLaps.lua` (`package.loaded` cleared first). Each leg is `map.getPointToPointPath(a, b)` (fallback: `map.getPath` between the nearest road ends); nodes behind a checkpoint are trimmed, a leg with no road becomes a straight line (`approx`). The line is resampled every 4 m, then **out-and-back spikes are cut**: where the line comes back within 6 m of a point after going further away, within 80 m of line (a checkpoint placed beside the road or on a spur, a side street's node at a junction, a turn across both carriageways); longer ones are real turn-arounds and stay (Highway Endurance turns round at checkpoint 3). Checkpoints on a cut piece move to the nearer end.
- **Routes:** id `qr_<track>` / `qr_<track>_rev`, `source = 'official'`, name (`" (reverse)"` added), `course`, `ccp` (stations of the course checkpoints, start and finish excluded). Gates are as wide as the checkpoint radius (up to 20 m). Built over several frames once the road graph is there (about 6 ms each, 123 ms for all 22 on West Coast USA); `getCourses()`/`setCourseEnabled()` finish the rest at once. The routes file keeps only official courses with something to keep (`enabled`, `best`, `laps`), never their line.
- **Rules:** a course times laps only when `enabled`. A valid lap on a course also needs every course checkpoint (`missed a course checkpoint`); `lapInfo` carries `name` and `checkpoints = {passed, total}`, `getState().active` carries `coursePassed`/`courseTotal`. A lap now starts only when the car crosses the start line while following the route there (`routeMatch` within `offTol` and 30 degrees): the gate of a start line on a corner faces diagonally, so the gate's own direction can't be used (Street Course 2 has one). The driver's own routes that an enabled course covers (90% of 20 sampled points on it, length within 10%) get `shadow = <course id>` and don't time (`getRoutes()` shows it as `course`); discovery's `sameRoute` already skips enabled courses. `clearRoute` refuses official courses; `getRoutes()` leaves them out.
- **API:** `coDriverLaps.getCourses()` → `{id, name, track, reverse, length, closed, enabled, best, laps, checkpoints, approx, missing}`; `coDriverLaps.setCourseEnabled(id, true|false)`. The settings panel row is for wave 2.
- **Tests:** `tools/offline/t_courses.lua` (a mocked layout over a mocked graph, see `tools/offline/README.md`); `t_laps.lua` unchanged and passing.
- **Live (2026-10-20, 0.40.1, West Coast USA, Vivace Ardente track, AI with `ai.driveUsingPath` over graph nodes sampled every 25 m along the course):** all 13 layouts load as 22 courses with their names (Street Course 1 2644 m, Street Course 2 2521 m, Highway Endurance 17.4 km, Long Race Circuit 1 4361 m, ...). Street Course 2 forward: 2:34.380, valid, 6/6 checkpoints; reverse: 3:07.901, valid, 6/6, with the forward course also on and taking no lap. Found on the way: the finish line of Street Course 2 is on a corner (hence the route-following start rule) and several courses had out-and-back spikes (hence the spike cut). The AI crashed into a kerb on the first reverse attempt; the teleport back kept that lap as an invalid partial lap, as designed.
- **Live testing note:** an AI drive with the coach on teaches the coach grip for the car (`settings/coDriverCoach_cars.json`; an AI lap replaced the author's legacy Ardente track values once it had 6 peaks) and adds debrief entries to `settings/coDriverCoach_history.json` (capped at 30, so old entries drop out). Back up those two files with the folder, and restore them after.

## Learned grip (2026-10-19)
- **What it learns:** per corner and braking event (`learnGrip` in `coDriverCoach.lua`), committed only after 3 s with no impact. Samples where lateral g doesn't match speed x yaw rate are ignored.
- **The value:** the 3rd highest of the 12 best clean peaks (x 0.92), so two freak values can't inflate it and easy corners can't lower it. Old single values stay ("legacy") until 6 clean peaks exist.
- **Console:** `coDriverCoach.gripDebug()` shows the learning state; `coDriverCoach.resetLearnedGrip()` forgets the current car and surface.
- **Keys:** model|config|surface. Custom (unsaved) configs are hashed to `custom-xxxxxxxx`, where they used to be the whole 90 KB parts tree; old keys are migrated automatically, keeping their values.

## Game 0.40 (2026-10-20)
Checked statically against the 0.40 game Lua: every game function the mod calls still exists (map, core_replay, core_groundMarkers, core_camera, core_vehicles, freeroam, spawn, damageTracker now at `lua/vehicle/damageTracker.lua`, powertrain, wheels, hydros, controller, sensors, beamstate; engine calls such as `Engine.Audio.*`, `debugDrawer`, `be:getFileStream`, `FS:stat` are still used by the game itself). Angular UI apps still load (the game ships 43 next to 62 Vue apps). Changes that mattered:
- **Driver camera is now an occupant camera** (`core/cameraModes/occupant.lua`, data keyed `occupant.<seat>` or `onboard.driver`). The settings keys (`cameraDriverFov`, `cameraDriverVehicleConfigs`) and `seatRotation`/`seatPosition`/`saveTimeout` are unchanged. `frameScreen` now finds it with `core_camera.getDriverCameraNameById(id)` (returns name and camera), falling back to `cams.driver`.
- **Replays:** 0.40 refuses replays recorded by older versions, and `core_replay.loadFile` only queues the load (the game shows its loading indicator and plays in `onUiWaitingState`), so it always returns success; a refusal shows the game's error and the state stays `inactive`. The analysis now tags each part with `gameVersion` (`beamng_versiond`), records the first time each version was seen (`settings/coDriverCoach/game_versions.json`), treats untagged files older than that as from an older version (no replay button, "recorded with an older BeamNG version" note, skipped in playback), and calls a load that plays nothing for 4 s a failure (`loadFailed`: one retry for a same-version file, then damaged). Settings offers "delete replays from an older game version". `t_replay.lua` has `MODE=refused` and `MODE=oldversion`.
- **Replay recording is nearly free in 0.40** (measured 2026-10-20 with `tools/perf_bench.sh`, forest route, default Vivace): fixed camera about 210 FPS with or without recording (+0.12 / -0.03 ms per frame; 0.39 was +1.87 ms at 102 FPS); driver camera 73.0 vs 72.4 FPS (about +0.1 ms; 0.39 was +1.3 ms), no frames over 20 ms either way (0.39: 94-131 per 25 s). Files grow about 33 MB a minute. The `laps` default stays; `always` is now cheap in frame time and only costs disk.
- **Live check (2026-10-20, 0.40.1):** after the update the game had **switched mods off** (`disableModsAfterUpdate`; the Mods button shows a warning) and skipped the author's `coDriverCoach_talk` wheel binding at startup because the action didn't exist yet; `core_modmanager.enableModsAfterUpdate()` (same as the in-game prompt) brought the mod back, and the binding (still in the inputmap file) worked again. Then: all four extensions load with no errors; recording, queued replay loading, playback, turn steps and camera restore work; the 0.39 replays are flagged with no load attempt; the framing lookup finds `occupant.FL`. Fixed during the check: the panel now raises its overlay above the game's new minimap while open; the recorder waits 5 s of not being wanted before stopping (a teleport left a 3 s file, which is also why the morning drive had 3 files); `coDriverRec` creates its shared table with `rawset` (no new-global warning); the compare row says when the studied lap is the best one. `core_camera.setByName(0, 'driver')` no longer switches to the driver camera; the occupant name (`occupant.FL`) does. The mod only restores the name it read, so nothing of ours depends on 'driver'.
- **Other notes to keep in mind:** road graph node ids were renumbered (nothing of ours stores them); drag and lift of most cars were retuned (lap times from 0.39 aren't strictly comparable); each occupant adds 89 kg (the car model reads mass from the car, so it follows); `wheels.lua` was split (the fields we read are still there); the game no longer sends `ChangeState` (we don't use it); failed `bngApi.engineLua` calls are now logged as errors.

## Lap review, settings, braking aid (2026-10-19 night)
- **Lap analysis:** `lapAnalysis(out, sess)` in `coDriverAnalysis.lua` runs after the session analysis (pcall). Laps (session times) map to grid index ranges; every lap of the best lap's route is projected onto the best lap's points (station only increases, window -3..+30 points), giving `points.ld` (time to the best lap per point), `points.lap` (lap key per point), sectors (thirds), a theoretical best (best 50 m cells of valid laps), spread (std dev), turns (the best lap's corners, matched in other laps by station within 30 m and direction: `c.turn`, `c.lap`, `c.vsBest`, `c.bestLap`). Lap keys are 1-based indices into `laps.list`; `bestLap` and `ref` are keys, not lap numbers. Laps averaging under 5 m/s (older versions' lap 1 with a long stop) are skipped. Offline: `tools/offline/t_lapscope.lua` (SRC=session) checks sectors add up and the end Δ matches.
- **Panel:** `lapSel` (key or null) scopes map, charts, corner list (`cornerLabel` = T<turn> in lap scope), Δ lane (`useLapDelta`), replay (`replayLap`). Engineer calls pass `lapSel` (`talkUp(sel, lap)`, `ask(q, mode, sel, lap)`; `reviewContext(sel, lap)` adds `laps` from `lapsContext`).
- **Engineer radio:** `focus_drive` sends only the asked-about car systems (all of them for a car check or setup question), else `carStatus` healthy/problems; `laps` (from `coDriverLaps.radioState()`) for lap or general questions. Rule: never add unasked car status. Whisper prompt has lap phrases.
- **Lap fixes:** `removeBacktracks` in `prepareRoute` (routes with a reset-jump repaired on load and saved; the author's r1 went 2155 -> 1981 m); teleport test uses the previous frame's speed and a capped dt; `findReturn` takes the most recent pass; `LAP1_MIN_V` 5 m/s.
- **Settings:** `coDriverAnalysis.requestSettings()` gathers `coDriverCoach.getSettings()`, `coDriverLaps.getOptions()/getRoutes()` and the analysis options into `CoDriverSettings`; `openSettings()` (strip ⚙). Coach `setOption` validates enums (brakeAid, voiceOutput, style) and clamps callAheadSec / voiceVolume.
- **Braking aid:** `cfg.brakeAid` off|bar|zone. `sendUI` brake gets `fill` (0-100, from 3 s before the brake point); the strip draws it as a gradient (`barStyle`). Zone: `M._drawBrakeZone` from `M.onPreRender` (no new top-level local; coach is at 196/200), prisms along `viewSamples` from the brake point (margin) to the corner's speed point (dist + 0.3 x (apexDist - dist)).
- **Bridge idle:** the game writes `engineer/game.json` every 20 s (a write costs about 1 ms on the GE thread); the bridge polls at 1 s while that file is over 60 s old (no file = fast). `beamng.log` can't be used: it is buffered for minutes.
- **Save cost (measured in game):** a 9-minute session reads in 11 ms, encodes in 36 ms (2.6 MB); the 45-minute cap (162k samples) 55 / 164 ms (14 MB); writes 2-4 ms. Once at the end of a drive, so left as is. Past 45 minutes the oldest 5 minutes are dropped at once instead of shifting every batch.
- **Coach split:** the scenarios section now lives in `lua/ge/extensions/coDriverCoach/scenarios.lua` (`require('coDriverCoach/scenarios').new(C, S)`; `package.loaded` is cleared first so a reload picks up edits). Shared state is the table `S` (stage, stageResult, pendingScenario, menuOpen) in the coach; `C` passes cfg, clock/drive accessors and wrapped helpers. `coDriverCoach._scenarios` exposes the instance (setupStage etc.) for tests. Coach top-level locals: 196 -> 182. deploy.sh copies the folder with the rest of the mod.
- **Lap compare:** `points.st` (station along the best lap) lets the panel line any lap up with any other (`compareSeries` in app.js: gap and the other lap's speed per point, cached per pair). `cmpSel` null = the best lap.
- **Strip sector split:** `sendUi` in coDriverLaps records the live delta at each third (`lap.secK/secD/secCum`), shown 6 s as `sector = {k, delta}`; offline test 16 drives `onUpdate` with a mocked car.
- **Spoken lap times:** engineer option `lapCalls` (off by default); `coDriverEngineer.onLap(info)` from `recordLap` sends a `say` with `spokenTime`/`spokenGap` ('one oh oh point five', 'two tenths off your best').
- **Replay storage:** `coDriverAnalysis.replayStorage()` / `deleteOldReplays('week'|'month')` (FS:stat filesize/modtime; skips the file being recorded or played). Only from the panel, confirmed.
- **Replay in laps mode:** `coDriverLaps.wantsReplay()` is also true anywhere on a saved route in its direction (routeMatch) and during a found loop's confirming lap.
- **Whisper check (synthetic):** 3 Kokoro voices + noise, 10 phrases: 25/30 exact with the old prompt, 30/30 with the lap phrases and 'Check car. Brakes? Radio check.' (script idea: kokoro create -> resample to 16 kHz -> transcribe with both prompts).
- **Engineer speech (2026-10-20):** `WhisperListener` keeps the mic open with a 0.5 s deque (`mic_preroll`), cleans the audio (mean and 10 ms moving average removed = high-pass ~100 Hz, peak normalised up to x20), uses `WHISPER_REVIEW_EXTRA` in review mode (the game sends `mode` with `listen`), retries with beam 5 and temperature fallback when avg logprob < -0.7 or compression > 2.4, and rejects Whisper's silence inventions and low-confidence noise. `fix_transcript` also maps "break" to "brake" before braking words; `apply_learned` applies `voicelog/fixes.json`. Synthetic benchmark (3 Kokoro voices, rumble, 12 phrases, old run clipped 0.2 s as a slow key press): 16/36 -> 30/36 exact at normal level, 0/36 -> 27/36 for a quiet mic, 0.93 s either way.
- **Voice log:** `voicelog/log.jsonl` gets a `heard` record per push-to-talk (wav, raw and fixed text, logprob, noSpeech, compression, retried, rejected, sttSecs) and an `answer` record per question (linked by `heard` id when the text matches the last clip within 60 s). WAVs rotate at `voice_log_keep`. `voice_review.py` merges them, stores `corrections.jsonl`, rebuilds `fixes.json`: phrase pairs corrected twice or more (one-word fixes keep the preceding word as context) and up to 20 vocabulary words. `VOICE_LOG_DIR` / `VOICE_REVIEW_PORT` override the folder and port (tests).
- **Measured per-frame costs (in game, parked):** coach onUpdate ~30 us average, engineer ~24 us average (all of it the timed file IO: bridge.json read 0.18 ms every 2 s, game.json write 1.1 ms, now every 20 s), laps 3.5 us, analysis 1 us, wantsReplay 2.5 us.
- **Engineer tokens:** review context keeps the 20 costliest corners plus the selected and studied-lap ones (7-lap drive: 37 KB -> 12 KB); the review system prompt is sent with cache_control, so follow-ups read it from the cache (measured: 7260 tokens written once, then read). Every Haiku call appends tokens and seconds (no text) to engineer/usage.jsonl (rotated at 1 MB).

## Phase A: where the time is (2026-10-20)
Plan: `docs/PLAN_FROM_RESEARCH.md` Phase A; method from ghost-racer-telemetry (`docs/EXTERNAL_PROJECT_RESEARCH.md` §2.1), reimplemented, no code copied.
- **Cells:** `lapAnalysis` splits each 50 m cell in 5 (`STRETCH.sub`; about 10 m, `laps.cells` cells of `laps.cellM` m along the best lap). Every lap of the best lap's route gets `l.tAt`: its lap time at each cell boundary from `lapTime(l, s)` (the existing projection), 3 decimals, -1 = not reached, `cells + 1` values.
- **Ownership:** against the best lap, the quicker lap owns a cell (a tie goes to the lower lap key, so A vs B mirrors B vs A). `ownerRuns` makes runs of one owner and merges a run under 3 cells between two runs of one other owner into them. A run's gain is the net time over its cells. Runs under 0.02 s or 0.01 s per 100 m are dropped; the rest are sorted by rate (s per 100 m), then by start.
- **Outputs per lap:** `l.stretches` (top 8 where it lost to the best lap: `s0`, `s1` in m along the best lap, `turn` = nearest turn id, `gain` s, `rate` s/100 m, `by` = the quicker lap's key, `where` = "T6 exit to 40 m before T7"), `l.ahead` (top 3 where it was quicker), `l.lost` / `l.gained` (totals of all kept stretches). The best lap's `l.stretches` are against the quickest valid lap of each cell (`by` says which lap). `laps.theoretical10`: the sum of the best 10 m cells of the valid laps; it can't be slower than the 50 m `laps.theoretical` (same boundaries) or the best lap.
- **Stretches are computed from the rounded `tAt`**, so the panel's JS (`lapStretches` at the top of `CoDriverAnalysis/app.js`, the same method) gets the same list for the same pair. The panel uses it for any compare pair and the Lua list for the best lap. Clicking a stretch finds the studied lap's grid range by `P.st` and zooms map and charts (`selectStretch`). The map's "quicker lap" mode colours the studied line by cell owner (`own`, 1 = compared lap, 2 = studied lap); the mode is kept in localStorage `cda.mapMode`.
- **Engineer:** `lapsContext` adds `whereLostVsBestLap` (3 stretches per lap, 6 for the studied one), `quickerThanBestLapAt` (2) and, for the best lap, `otherLapsQuickerAt`; `theoreticalBest` is the 10 m one. 7-lap drive: the laps context is 3.8 KB.
- **7-lap session (20261019_211229, best L2 1:00.309):** theoretical 57.03 s from 10 m cells, 57.69 s from 50 m. L1 (+1.96 s) loses most in T7 entry to T8 entry (0.99 s, 0.67 s/100 m); kept stretches lost 3.13 s, gained 1.14 s. L4 (+7.14 s): T9 exit to T10 exit 6.10 s (5.11 s/100 m, the slow last part), T1 exit 0.30 s, T2 exit to T4 exit 2.42 s.
- **Tests:** `tools/offline/t_lapscope.lua` (cell times add up to each lap's gap within 0.01 s, time lost in cells at least the gap, kept stretches lost minus gained within 0.1 s of the gap, gains positive and in rate order, theoretical 10 m <= 50 m <= best, a synthetic flicker merge, and with `ENG=` the engineer's lap context; `OUT=` writes the result). `tools/offline/panel_stretches.js <app.js> <result.json>` loads the panel with a stub angular and checks its stretches against the Lua ones for every lap.

## Phase B: engineer, local answers and checks (2026-10-21)
- **Local answers** (`local_answer` in `tools/engineer.py`, drive mode, before any API call): radio checks ("Loud and clear."), acknowledgements ("Copy."), garbled speech ("Say again?": no driving word and either Whisper's logprob under -0.55, kept in `LAST_HEARD`, or 3 words or fewer), last lap / best / running delta from `laps` (the lap timer's `radioState`, spoken the way the lap calls are), speed, "what have you changed", a car check, and one-topic status questions (`offline_drive`). Open questions (why, should, where, compare...), car changes and anything over 8 words go to Haiku.
- **Event ring** (`coDriverEngineer`): `events`, last 50, polled once a second from `coDriverCoach.getDriveEvents(from)` (corners with min speed against the called speed, crashes, resets), plus laps (`onLap`) and alerts. `driveContext().recent` = the last 12 of the past 10 minutes ("35 s ago: corner 3 Left at 54 mph, over the called 48 mph"); `focus_drive` sends them for event, lap and general questions.
- **Reply checks** (drive): a reply with several paragraphs keeps the last (Haiku drafts, then answers); `leaks()` (talks about "the driver", the question, the rules) → `strip_leaks` drops those sentences, else one retry, else "Say again?" or the rule-based answer. `unsupported_numbers()`: a number over 10 not in the data (within rounding; whole numbers within 1) nor a difference of two decimals in it → one retry with the numbers named. Reviews get the number check too.
- **Thinking:** Haiku 5.5 takes `thinking: {type: adaptive}` with `output_config.effort` (no `budget_tokens`: "enabled" is refused). Drive answers use it at low effort by default (`drive_thinking`): without it 3 of 7 Haiku answers drafted out loud and one misread a lap time; with it all 7 were clean, p50 2.1 s against 1.5 s.
- **Review tools** (`review_tools`, off): brief (18% of the 13.5 KB analysis) plus `corner_detail`, `lap_detail`, `lap_compare`, `turn_detail` (each under 1.5 KB, 4 rounds at most, debriefs think). Measured on the 7-lap drive, 10 questions: 66% more cost (input-token equivalents with cache prices, 36.6k against 22.1k), p50 2.8 s against 1.6 s, similar answers. The whole analysis is cached after the first question and every tool round is a full call, so the full prompt stays the default.
- **Tests:** `tools/test_engineer_local.py` (offline, fixtures in `tools/tests/fixtures/` captured from the game), `tools/engineer_eval.py` (live, 30 questions: 20 drive incl. the voice log's garbled ones, 10 review; prints answers, local share, p50, tokens, cost). Last run: 13 of 20 drive questions local, 0 answers with numbers not in the data, drive p50 0.0 s overall and 2.1 s for Haiku answers. `tools/test_engineer_adjust.py` still passes (its fake API now takes extra keyword arguments).

## Security (2026-10-23)
See `SECURITY.md`. Hardening from the audit:
- **`voice_review.py`:** answers only with a Host of `127.0.0.1:<port>` or `localhost:<port>`. POSTs need the per-run `X-Review-Token` (embedded in the page) and a local Origin, have a 100 KB body cap, and must be JSON objects.
- **`engineer.py` `handle()`:** drops requests whose id isn't `[A-Za-z0-9_]{1,40}`, because the id names the reply file. It starts PowerShell by its full system path.
- **Loading:** `coDriverLaps.loadRoutes` drops a malformed start gate (it is rebuilt), best and laps; `readSession` coerces `fmt`.
- **Panel:** `q()` replaces control characters and lone surrogates (JSON's `\u00XX` isn't valid Lua). The scenarios panel strips everything outside printable ASCII.
- **Retest:** the fuzz harnesses (not in the repo) were rerun after these changes. The voice review server refuses cross-site and rebinding requests (403), bad ids write nothing, `q()` compiles for 20,000 random inputs, and corrupted routes files no longer throw.

## Phase F: recce pacenotes, your voice for short lines (2026-10-21)
- **Recce** (`coDriverCoach/recce.lua`, required like `scenarios.lua`; `new(C)` with cfg, say, announce, log, notify). Position along the route comes from `coDriverLaps.getProgress()` ({level, route, n, prog, len, closed} while a non-tentative lap is timed). `recceArm(true)`: the next lap that starts records; `callNotes` reports each call with `recce.onCall(note.dist, words, text)` **before** the distance prefix ("150,") is added, stored at s = prog + dist (wrapped on loops), deduped within 10 m. When the lap key (route#n) changes the recording is kept if it covered 300 m+ (`covered` = the loop length for a completed loop, else the furthest progress). File `routes/<level>_recce/<route>.json`. Playback: `recce.update(callDist, moving)` runs every path tick **before** the speed check (a lap that ends while stopped is still seen), calls entries when callDist ahead (> 6 m), wraps the next lap's first corners and carries them over (`nextDone`) so they aren't called again after the line, and returns true inside `covered` (the coach's own corner calls are skipped). Past a partial recce it returns how far ahead it already called (+30 m); the coach marks those notes called.
- **Live check (r1, AI, 2026-10-21):** recce recorded 17 calls over 1,437 m (the AI's path ends there); runs 2 and 3 made exactly the same 12 calls in the logged window (1 Left ... 2 Right long opens). After the recce ends the coach's own calls resume; when the AI stops and restarts at its path end the coach can repeat a call (its 15 m dedupe misses when it nearly stops) - seen without the recce too.
- **Your voice:** `coDriverCoach.sayPhrase(text)` greedy-matches the words (up to 4 per clip name: nice_save, brake_hard, are_you_okay) to the voicepack's clips and queues them, false if any word is missing; `voiceWords()` lists the clip names. The engineer's `radio()` (alerts) tries it first (`ownVoice`, default on); asks send `voiceWords` when speaking, and the bridge's `voice_cover()` (same rule) sets `res.ownVoice` instead of speaking with Kokoro, so the game says it. The author's pack (`custom`, 120 clips) covers short lines only.
- **Final review (2026-10-21, an independent review agent over the whole night's diff), fixed:** a deleted route's id is given out again, so `clearRoute` now deletes its best-lap and recce files (`clearLaps` the best file) and a recce whose length differs by over 3% or whose loop/point-to-point kind differs is ignored; the ghost reloads as soon as a new best is kept (`coDriverLaps.bestChanged`), not a lap later; a partial recce makes no wrapped calls before the line; inside a recce the coach's own notes are marked called, so it doesn't repeat them when the lap or the recce ends; `recceArm(true, route)` arms one route (the settings rows pass theirs); `sayPhrase` refuses while the coach is off or a replay plays, and an answer the bridge left for your voice falls back to Kokoro; short open questions ("Any advice?", "Why?") go to Haiku (only short remarks without a '?' or unsure speech get "Say again?"); `bestFromSamples` needs samples covering the whole lap; the owner-map legend says "best ever quicker". **Left as is:** caution words are kept in recce notes as recorded (as on a real recce; a fast recce warns more than a slow one); the backfill finds a route's old best only in a session whose quickest lap it was (the index keeps one best per session).
- **Tests:** `tools/offline/t_recce.lua` (with recce.lua as the extension: record, two laps at different speeds give the corners in route order once per lap with nothing repeated across the line, partial recce, hand-back, clear), `OwnVoice` in `tools/test_engineer_local.py`.

## Phase E: balance and measured power (2026-10-21)
- **`balanceOf(g, lim)`** (coDriverAnalysis, after `carModel`): per 4 m grid point, path angle from the neighbours, slip angle beta = heading (DX, DY) minus path angle, curvature over +-2 points. Steering gain = median curvature / steering input over calm cornering (v > 8, |lat| < 0.3 mu, |str| > 0.03, |beta| < 2.5, at least 30 points); it is negative on the Vivace (steering + = right, curvature + = left), which the sign handling expects. **Oversteer (2):** rear out (beta toward the inside of the turn) over 5 deg, or over 2.5 deg with countersteer. **Understeer (1):** |str| > 0.05, |lat| > 0.5 mu, curvature under 65% of gain x steering, rear out under 3 deg. A flag needs 2 points in a row. `pts.bal`, `corner.balance` ("pushed wide on entry", "rear stepped out on exit", from 2+ points between brake point and apex, or apex and exit), `model.steerGain` (nil = no steering in the recording: **AI drives record steering_input 0**, so only oversteer is judged there).
- **Measured power** (`carModel`): mass x TLON x speed on samples at full throttle (> 0.9), no brake, same gear, over 8 m/s; 90th percentile per 5 m/s bin (15+ samples), best bin -> `model.powerMeasuredKW` / `powerMeasuredKmh`. On four Vivace drives: 207-224 kW at 99 km/h against 270 kW listed (77-83%: drivetrain loss and drag, which isn't added back).
- **Panel:** map button **balance** (`mapMode` 'balance', stored like 'owner'), legend, "Balance: ..." in the corner detail, measured power in the car line. **Engineer:** `corners[].balance`, `power`, `balanceNote` in the review context.
- **Numbers (7-lap session):** 6.2% of points understeer, 0.7% oversteer, 21 of 76 corners with a note; the author's morning drive 9.4% / 1.0%. The one 'lost' corner with understeer (corner 71) was pushed wide, not a spin: 'lost' isn't always a slide. No drive in the archive has a 'spin', so `t_balance.lua` adds a made-up slide (heading turned up to 25 deg into the turn through an apex) and checks it is flagged.
- **UI test note:** `ui_eval` (tools/bmcp.py) evaluates a single expression: statements (`;`, `if`, `var`) silently do nothing. Click with a comma expression guarded so the dispatch-and-read pair clicks once: `(window.__k = (window.__k || 0) + 1, window.__k === 1 && el.click(), el.className)`.

## Phase D: best laps across drives, ghost (2026-10-21)
- **File:** `settings/coDriverCoach/routes/<level>_best/<route>.json` = `{version, level, route, time, date, session, car, pts = {x, y, z, t, v, thr, brk}}`, 4 m points from the lap's samples (`bestFromSamples` in coDriverAnalysis; nil on a >30 m jump or under 25 points). About 20 KB for the 2 km loop.
- **Written** when `coDriverAnalysis.onLap` gets a lap with `best`, valid, not partial: `rec.pendingBest` waits until a batch has samples past `t1 + 0.3` (`_flushBest` in `onChunk`; `endSession` forces it). Live-checked 2026-10-21 with a made-up lap on a running recording (file written on the next batch, last point 39.7 s of 40). **Backfill:** `ensureBestEver(level, route, time)` finds the archived session whose index `bestLap` matches and saves that lap; coDriverLaps queues one per second, 3 s after a level loads, for every route with a best.
- **Review:** `lapAnalysis` projects the file onto the drive's best lap (accepted if it covers 90% and under 10% of points are over 25 m off) and adds `laps.bestEver = {time, date, car, session, same, tAt, vAt, line, stretches, ahead, lost, gained}`; `same` = it is this drive's best lap. The panel offers it in COMPARE WITH as `'ever'` (`everSeries` in app.js reads its `tAt`/`vAt` at each station; `lapStretches` gives the list).
- **Ghost:** `coDriverLaps.onPreRender`, option `ghost` = off (default) / marker / line. Marker = `drawSphere` at the best lap's position at the current lap time (`ghostAt`, a moving index); line = 50 `drawSquarePrism`s from the point nearest the car (window -5..+40, full search after a reset). Measured 0.042 ms CPU a frame in game. Off during replays.
- **Settings panel:** lap timing has the ghost row and the official course list (`getCourses`, `setCourseEnabled`); `requestSettings` sends `laps.ghost` and `laps.courses`.
- **AI test drives** on official courses leave the route (the AI cuts or misses the course's own path), so a course lap from the AI ends "left the route"; test saving with a made-up lap instead (above).
- **Tests:** `t_bests.lua` (`SRC=` the 7-lap session: backfill, file points, same-drive flag, lap 3 as best ever lines up within 0.15 s, stretches, line), `t_laps.lua` test 17 (ghost position, end, option validation).
