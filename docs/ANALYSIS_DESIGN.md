# Post-drive analysis: design notes

Goal: after a drive, a "race engineer" review. It shows where time was lost, a theoretical better line, speed and braking compared with what the driver did, replays of the bad moments, a draggable timeline over the telemetry, and an end-of-session prompt ("Keep recording" / "Review analysis").

## A. Methods (from the racing-line and telemetry research)

### Better line (minimum curvature within the road width)
Parameterise the line as lateral offsets from the centreline: `p_i = c_i + α_i·n_i`, where `n_i` is the unit left normal and `|α_i| ≤ w_i − margin` (half-width minus half the car width plus a buffer). The real method (TUM, Heilmeier et al.) minimises Σκ² as a QP. A Lua-friendly substitute is iterative Laplacian smoothing (an elastic band):
```
resample centreline every ds≈4 m; α_i = 0
repeat N=150..300:
  for i = 2..n-1:
    L = 0.5*(p[i-1]+p[i+1]) - p[i]
    α[i] = clamp(α[i] + 0.5*dot(L, n[i]), -wmax[i], wmax[i])
  (endpoints fixed at α=0 for an open stage)
κ_i = Menger curvature = 2*cross(a,b)/(|a||b||a+b|), then a short moving average
```
This gives outside-apex-outside geometry on its own. Add an "own lane only" option for public roads by bounding α to one side.

### Ideal speed profile (three-pass, quasi-steady-state)
```
μg = driver's own grip: 97th percentile of sqrt(ax²+ay²) (or the coach's learned lat/brake g)
v_lim[i] = min(vmax, sqrt(μg/|κ_i|))
forward pass:  v[i+1] = min(v_lim[i+1], sqrt(v[i]² + 2·a_acc·avail·ds)), avail = sqrt(1-(v²κ/μg)²)
               a_acc ≈ fit of the driver's max ax vs speed (power limited)
backward pass: v[i]   = min(v[i],      sqrt(v[i+1]² + 2·a_brk·avail·ds))
```
Values that come out of it:
- **Ideal ax:** `(v_{i+1}²−v_i²)/(2ds)`. The ideal time is Σ 2ds/(v_i+v_{i+1}).
- **Ideal brake point:** where ax first drops below −0.1 g before a corner.
- **Ideal brake trace:** `−ax/a_brk_max`. It peaks first and tapers, which is the trail-braking shape.
- **Ideal minimum (apex) speed:** the local minimum of v.
- **Ideal throttle pickup:** the first ax > 0 after the apex.

### Comparing the driver with the reference
- **Align by distance on the reference path**, not by time or each lap's own distance. Project samples onto the path to get s, then resample on a common s grid.
- **Time delta:** `Δ(s) = t_drv(s) − t_ref(s)`. A rising slope means time is being lost there.
- **Per-corner loss:** `Δ(exit + 50–100 m) − Δ(brake start − 20 m)`. Rank corners by it and show the **top 3**.
- **Watch for false gains:** braking deep but missing the apex looks fast until the exit, so always check exit speed about 50 m after the corner.
- **Key metrics per corner:**
  - brake point vs ideal (m)
  - minimum speed vs ideal, and where the minimum happens relative to the apex
  - exit speed
  - distance to full throttle
  - coasting time
  - G-G use

### Coaching rules (starting thresholds, tune on BeamNG data)
| Issue | Detection |
|---|---|
| Brake too early | onset more than 10 m before the ideal point, and min speed ≤ ideal |
| Brake too late / over-slowing | onset late but min speed more than 5% below ideal, or the minimum well before the apex |
| Too-gentle initial brake | brake from 5% to 90% of peak takes more than 0.3 s, or peak decel < 0.8·a_brk_max |
| Brake dip / re-apply | inside the zone, brake drops more than 15% then rises more than 10% |
| No trail braking | brake < 5% before steering exceeds 20% of the corner's peak |
| Coasting | brake < 5% and throttle < 10% for more than 0.3 s between brake release and throttle |
| Late throttle | throttle > 20% starts more than 0.5 s or 15 m after the ideal pickup |
| Hesitant throttle | more than 2 throttle-rate reversals, or a stepped ramp |
| Sawing | more than 2 steering-rate sign changes per second, amplitude > 0.03, inside the corner |
| Too much lock | steer/ay more than 1.3× the driver's median, with ay < 0.85 μg |
| Unused grip | less than 30% of corner samples above 0.85 μg combined g |

### UI patterns
- **Stacked charts on a shared distance x-axis** with one draggable cursor and zoom. Order: Δ, speed (you vs ideal), throttle and brake, steering, gear/rpm.
- **Track map** with a cursor dot. Your line is coloured by gain/loss or speed; the ideal line is a ghost or dashed.
- **Corner list sorted by time lost.** Clicking a corner zooms all charts to it and shows one plain sentence, e.g. "Braked 18 m early, min 72 vs 81 km/h, throttle 0.6 s late".
- **G-G plot for the selected range.**
- **For beginners:** biggest losses first, at most 3 tips, consistent colours (you vs ideal), values labelled at the cursor.

Sources: TUM minimum curvature (portal.fis.tum.de; arXiv 2403.11784), three-pass speed profile (arXiv 1902.00606), HPAcademy driver and braking analysis, MoTeC forum notes on distance alignment, Track Titan, Coach Dave Delta, Fanatec trail-braking and throttle guides.

## B. Replay API (BeamNG 0.39.4, `ge/extensions/core/replay.lua`)
- **Continuous playback (v2):** `playFrom(t)` is the one entry point. Within the loaded file it is a seek; otherwise it loads the part holding t, and `onReplayStateChanged` seeks once ready.
  - `updateReplay` hands over to the next part when the clock reaches its `t0` or the file's end (`totalSeconds - offset`, in session time).
  - Gaps between parts are skipped with a timed note. At the last part's end it pauses, and play starts over.
  - The current turn is the last one whose approach (`tStart - 3`) has started. `replayStep(±1)` seeks to the next turn's approach, or to the previous one (the current one if more than 2 s in).
  - `drawReplay` draws the better line from about 30 m behind to 160 m ahead of the car and your line over the last 160 m. Corner markers fade in over `tStart - 6 .. tStart - 4` and out over `tEnd .. tEnd + 2.5`.
  - Tested offline with a mocked core_replay (`tools/offline/t_replay.lua`).
- `core_replay` is always loaded and wraps the C++ stream `be:getFileStream()`. Stream methods: `record(fn)`, `play(fn)`, `stop()`, `seek(0..1)`, `setPaused`, `setSpeed`, `stepTime(s)`.
- **Quiet background recording:** `be:getFileStream():record('replays/codriver/<name>.rpl')`. Going through `core_replay.startRecording()` instead pops a toast that never times out. Only one stream can run at a time, and a mission auto-replay stops ours.
- **Play a moment:**
  1. `core_replay.loadFile(fn, false)` (game-relative path under `replays/`, `.rpl`). This also stops any active recording.
  2. Wait for `onReplayStateChanged` to report `state == 'playback'` and `totalSeconds > 0`.
  3. Call `core_replay.seek(t/total)`, `setSpeed(x)`, `pause(false)`. `core_replay.getPositionSeconds()` gives the clock.
- **Exit:** `core_replay.stop()`. Replay recreates vehicles, so re-set the camera afterwards and restore the car pose with `spawn.safeTeleport` if needed.
- **Hooks:**
  - `onReplayStateChanged(state)` fires on every position update. `state` has `state`, `positionSeconds`, `totalSeconds`, `paused`, `speed`.
  - `onReplayCoreEvent` fires on events such as `recordingStarted` and `playbackStarted`.
- **Cameras during playback:** `core_camera.setByName(0, 'orbit'|'chase'|'driver'|'external')` works, since camera actions stay active.
- **3D overlay:** `debugDrawer` is immediate-mode and keeps working during playback. Redraw every frame in `onPreRender`:
  - `drawLineInstance(a, b, width, ColorF)` for lines
  - `drawSphere(pos, r, ColorF)`
  - `drawSquarePrism(a, b, Point2F(h,w), Point2F(h,w), ColorF)` for ribbons
  - `drawTextAdvanced(pos, String(txt), ColorF, true, false, ColorI)` for labels
- **Ghost car:** none is built in. A ghost would need a second car following `ai.startFollowing(script)`, so it's skipped for v1. The better line is drawn as a 3D ribbon instead.
- **Unverified:** `.rpl` size per minute; drives are rotated and pruned, keeping the last few.

## C. Telemetry and UI plumbing
- **Recording at a steady rate:** a vehicle-VM extension (`lua/vehicle/extensions/coDriverRec.lua`) samples in `updateGFX(dt)` at most every 16 ms (every frame at 60 fps, about 60 Hz above), timestamped with the summed frame dt, skipping frames where dt = 0 (paused). It was 20 Hz in v1; see F. Every 0.5 s it sends a batch to GE with `obj:queueGameEngineLua`. The GUI streams are a poor fit: they go straight to the UI, at the UI rate, and only while an app is listening.
- **Channels:**
  - inputs: `electrics.values.throttle_input`, `brake_input`, `steering_input` (raw pedals), plus `gearIndex`, `rpm`, `wheelspeed`, `absActive`
  - position and velocity from `obj:getPosition()` / `obj:getVelocity()`
  - **brake pressure proxy:** the mean over wheels of `wheels.wheelRotators[i].brakingTorque / brakeTorque` (there is no hydraulic pressure value)
  - accelerations computed in GE from velocity differences
- **Transfer to the UI:** `guihooks.trigger` JSON-encodes the payload, as `bngApi.engineLua(cmd, cb)` does. Stock apps send `map.getMap()` this way, so a few hundred KB is fine. Analysis results go on a 4 m grid (2.5k points per 10 km), rounded, plus your inputs at full rate (see F).
- **Storage:** `jsonWriteFile(path, t, false)` (non-pretty is fast). The last session is saved to `settings/coDriverCoach/last_session.json`.
- **Charts:** no usable library ships (Smoothie only scrolls in real time; Chartist SVG is too slow). Use raw canvas 2D: draw the data on one canvas and the cursor on an overlay canvas, so dragging doesn't redraw the data. Use the min/max of each pixel column for long ranges, mouse-wheel zoom and drag-pan.
- **Map:** level `info.json` has `minimap` tiles (`file`, `size`, `offset`; world (x,y) maps to image (x−offX, offY−y)). For v1 the road is drawn as a band, centreline ± width from the road graph, which works on every level.

## D. Plan (v1)
1. **`coDriverRec` (vehicle VM):** a 20 Hz sampler sending batches to `coDriverAnalysis.onChunk`.
2. **`coDriverAnalysis` (GE):**
   - Starts a session when the car moves with the coach on: telemetry plus a quiet `.rpl` (`replays/codriver/`, keeps the last 4).
   - Splits the drive into segments at teleports, gaps and stops longer than 5 s.
   - For each segment:
     1. Resample to the 4 m grid and snap to the road graph (centreline and width).
     2. Smooth the line (min-curvature) within the bounds (road width, widened to wherever the driver actually went).
     3. Run the three-pass ideal speed profile with the driver's grip, braking and acceleration envelope.
     4. Compute Δ, detect corners from ideal braking zones (plus braking the driver did that the ideal line doesn't need), and run the per-corner rules.
   - Ranks corners by loss and builds the top habit tips.
3. **`CoDriverAnalysis` UI app:**
   - Full-screen review: map (road band, your line coloured by gain/loss, the ideal line as a ghost, cursor), corner list, and stacked charts (Δ / speed / brake and throttle / steering / gear) with a shared draggable cursor and zoom.
   - Replay mode: a compact bottom strip whose cursor follows the replay. Dragging it seeks the replay.
4. **Replay:** load the `.rpl`, seek to the corner's ideal brake point minus 4 s, use the orbit camera, and draw the ideal line (green) and your line (orange) in 3D, with brake, apex and throttle markers. Pause at the corner exit; Exit restores the car pose and camera.
5. **End of session:** the debrief gets **Keep recording** (dismiss; the session continues) and **Review analysis** (stop, analyse, open the panel).

## E. Measured in game (2026-10-18)
- The telemetry and replay clocks agree to within about 0.02 s, so seeking to a corner lands on it.
- `.rpl` size is about 57 MB per minute. That's why replays rotate in 5-minute parts, keep a 20-minute window, pause after 90 s parked, and keep only the current and previous session.
- Analysis takes about 0.03 s per 1.5 km (LuaJIT). The UI payload for a 4 m grid is fine to send through `guihooks.trigger`.
- The game's own "Recording mm:ss" HUD appears while the quiet recorder runs. That's acceptable, since it shows recording is on.

## F. v2 upgrade (2026-10-18): smoother telemetry, wall-aware line, car and style model

### Telemetry
- `coDriverRec` samples about 60 Hz. Each sample adds two fields: **tyre load** (Σ wheel `downForceRaw` / the car's weight from `calcBeamStats().total_weight`) and **surface class** (the ground material carrying most of the load: `contactMaterialID1`, or `ID2` when ID1 is 4 = the tyre's rubber, mapped by `particles.getMaterialsParticlesTable()` names to 1 tarmac, 2 wet, 3 gravel/dirt, 4 grass/mud/sand, 5 snow/ice; 0 airborne). Sessions carry `fmt = 2`. Older 20 Hz sessions (17 fields) still load: `loadLast()` strips anything an older analysis appended.
- At start it sends `coDriverAnalysis.onCarInfo(id, {mass, powerKW, brakeN, driven, abs, wheels})`:
  - `powerKW` is the engine's `maxPower`, which the game gives in hp, × 0.7457
  - `brakeN` is Σ `brakeTorque / radius`
  - `driven` comes from which `isPropulsed` wheels are front or rear (by name)
  - GE adds `halfWidth` from `veh:getInitialWidth()`
- The analysis grid stays 4 m (model, map, corner indices). The charts get `result.trace`: raw samples kept every 0.5 m or 0.1 s (`s, v, thr, brk, bp, str, gear, rpm, lat, seg`), on the same distance axis (`sOff` + driven distance). The driver channels left the 4 m `points`, which now hold only what the map and model need.
- Accelerations use a ±0.1 s window by time, split along and across the **velocity** direction (heading in a slide is not the path), which is what `v²κ` in the speed model means.
- The panel draws the trace with min/max per pixel column when zoomed out and plain lines when zoomed in. The cursor is a continuous distance; replay sync and seeks interpolate time on the grid (`sAtT` / `tAtS`).
- Payload estimate for 15 minutes: about 2.6 MB at a 100 km/h circuit pace (50k trace samples at about 41 B, 5.6k grid points at about 93 B); about 1.6 MB at a 60 km/h rally pace. v1 sent about 0.9 MB for 25 km.

### Walls (better line bounds)
- The road graph gives the centreline and radius. Edges are now measured from the graph projection in the smoothed centreline's frame (`roadL`/`roadR`), because the 5-point smoothing cuts inside tight corners. A 5-point median on the edges removes the one- or two-point spikes where the projection snaps to a crossing road at a junction; without it the line kinks there.
- **Walls:** from your position at each grid point, `castRayStatic(origin, dir, maxDist)` (GE global, returns the hit distance or maxDist; static collision includes terrain, meshes and forest items) is cast left and right:
  - at 0.6 m and 1.2 m above the ground (found with a short ray down)
  - following the road's crossfall (from a second ground probe 1.5 m out), so camber or banking isn't a wall
  - the nearest over ±1 neighbours counts, since a ray can slip between trees
- **Bounds:** road edge minus half the car's width and an edge margin, widened to where you drove (at most 1.5 m past the edge), then clamped to wall minus half width minus a wall margin. Your own line is always allowed. Off-graph stretches stay within ±0.3 m of your line.
- **Clip check:** after smoothing, every step of the line is raycast across the car's width:
  - low rays every 0.3 m or so across the width, plus one high centre ray
  - plus the lateral path from your line to the ideal point
  Blocked points move their bounds 50% toward your line (neighbours 25%), the band is re-smoothed, and the check repeats up to 4 times (`model.clipFixes` counts the points moved).
- Synthetic tests (`tools/offline/t_walls.lua`):
  - walls at 3 m / 4 m on a 6 m graph: the line keeps 1.24 m (half width + margin) and offsets 1.6 m inside instead of 4.6 m
  - a thin post between ray positions: caught by the clip check

### Car model (`carModel`)
- **Aero:** the load factor on steady running (|lat|, |lon| < 0.25 g), normalised by its 5–15 m/s mean, fitted as `1 + aero·v²`. It is never negative, and capped at +50% at the drive's top speed.
- **Grip:** corner events are runs of the 0.5 s average of |lat| above 0.3 g lasting at least 0.4 s. Each event's peak is divided by the aero load. The estimate per surface is a robust top: the 85th percentile, never the single best when there are 3 or more.
  - Windows within 1.5 s of an impact (raw combined over 2.3 g) are excluded.
  - Surfaces with fewer than 3 events scale from the main one by default ratios (wet 0.8, gravel 0.72, grass 0.55, snow 0.35).
  - The coach's learned grip is only a fallback.
- **Braking:** the robust top of your sustained braking peaks as a share of that surface's grip. It is at least 0.9, because tyres brake about as well as they corner, at most 1.5, and capped at 95% of the brake torque limit (`brakeN / mass`).
- **Acceleration:** p90 of full-throttle `lon` per 5 m/s bin with at least 8 samples. Elsewhere `min(traction, 0.8·P/(m·v))`, scaled by the median data/physics ratio. Traction is the grip × 0.95 for AWD, × 0.55 otherwise.
- **Margin:** cornering and braking limits are multiplied by the margin (default 0.95). Corner speed solves `v²κ = m·μ(1 + aero·v²)`.
- The ideal brake trace is in **pedal** terms: the share of the limit × the pedal the limit needs (`pedalAt`, below 1 when the brakes are stronger than the tyres).

### Style and rules
- Style is auto: circuit on `hirochi_raceway` / `automation_test_track` (with under 25% loose surface), rally everywhere else. A wall-share rule was tried, but forest trees count as walls and turned forest roads into "circuit". The style can also be forced.
- | | edge margin | wall margin | brake point tolerance | wide of apex | coasting |
  |---|---|---|---|---|---|
  | circuit | 0.2 m | 0.3 m | max(8 m, 10% of the zone) | 0.8 m | 0.3 s |
  | rally | 0.5 m | 0.5 m | max(15 m, 15% of the zone) | 1.5 m | 0.5 s |
- Brake squeeze tolerance is 0.3 s with ABS and 0.45 s without. Low peak brake means under 75% of the ideal pedal peak when that peak is over 45%. Grip use is measured against the full speed- and surface-dependent limit.
- Settings: `coDriverAnalysis.setOption('margin', 0.9|0.95|1)` and `setOption('style', 'auto'|'rally'|'circuit')`. They are saved to `settings/coDriverCoach/analysis_settings.json` and re-run the analysis; the panel's **model** button sets them.
- `result.model` summarises the model for the panel: margin, style, grip and braking, aero gain at 150 km/h, per-surface grip, brake capacity, power, mass, drive, ABS, and wall clip fixes. `result.limits.lat/brk` (used by the engineer) is now the main-surface target after the margin.

### Review layout and tone (v2)
- Map first: the map takes most of the panel; strengths, tips and the corner list sit beside it. Telemetry charts are behind a toggle (always on in replays). Model and engineer settings are under **settings**.
- Positives: `judgeCorner` also records what went well, in order of importance: pace (loss < 0.1 s), brake point within 60% of the tolerance, apex speed at 97% or more, exit at 97% or more, trail braking, a firm brake (rise ≤ 0.2 s), early throttle (≤ 0.25 s), no coasting, apex within 0.5 m, smooth steering. Corners show up to 2 (`good`). `result.strengths` lists up to 3 that showed up at least twice, most important first.
- Notes and tips are worded as what to try ("Room to brake 18 m later", "Carry more to the apex: 72, 81 km/h possible"). There are 2 tips and at most 2 notes per corner.
- The corner list and replay prev/next go in turn order by default, or by time lost (saved in the panel's localStorage).

### Incidents and damaged replays (v2.1)
- **Incidents:** `judgeCorner` flags a corner as an incident when any of these hold:
  - `crash`: a raw combined acceleration over 2.5 g
  - `spin`: the heading more than 50° from the velocity for over 0.5 s, or over 100° at any point, with min speed under 70% of ideal
  - `off`: 3 or more grid points over 2 m outside the road edges, with min speed under 70%
  - `lost`: min speed under 40% of an ideal over 8 m/s
- Afterwards, corners under 75% of pace count as `after` (slow after the incident) until a corner is back at 85% or more, or 60 s pass.
- Incident corners get no findings or positives, so they stay out of tips and strengths. `result.gapClean` and `result.incidents` give the headline without them, and the engineer context gets them too.
- On the 311 s WCUSA run that went wrong, corners 7–12, 15 and 39 were flagged: 47.2 s to find, 13.9 s without incidents.
- **Rotation:** `stopReplayRecording` marks `replayStopT`, and the next part only starts once the stream reports `inactive` for 0.5 s. Previously it started in the same frame, after a second `stop()`.
- **Live test:** 20–40 s parts, 10 rotation stops, and 1 file still came out unreadable ("Couldn't read last packet: 3"), at 9 km/h. Speed isn't the cause, and the rest looks engine-side.
  - So playback treats unreadable files gracefully: `loadFile`'s result is checked, and a failure goes into `settings/coDriverCoach/damaged_replays.json`.
  - It is noted once and skipped to the next part. `hasReplay` and the corner buttons are refreshed, and it is never retried.
- **Pruning:** replays of the 2 newest archived sessions are kept too. The index lists each session's replay files, so an extension reload, which forgets `lastSession` and `recentSession`, can't delete them.
- **Exit restore:** `spawn.safeTeleport` turns the rotation by `quat(0,0,1,0)`, so the saved rotation is passed as `rot * quat(0,0,-1,0)`. Verified live: the same heading to 4 decimals.
- **Seeks:** `core_replay` can deliver one more position update from before a seek. Updates within 0.5 s of a seek that are over 1 s away from its target are ignored.
- **Turn steps:** prev/next are based on the current turn (5 and 6 can be only 3 s apart). Live: 4 → 5 → 6 → 7 → 6 → 5.

### Session archive
- Every session of 60 s / 500 m and more is written as `sessions/<stamp>_<level>_<model>.json`, in the same format as last_session.json (recorded fields only, non-pretty, encoded once for both files), plus `index.json` (name, date, level, model, km, secs, fmt). The archive keeps the newest 20.
- Replays stay limited to the current, reviewed and last recorded sessions (`recentSession`, so opening an old archive doesn't prune the latest drive's replays).
- `readSession` normalises any version: 17 fields for 20 Hz, string keys repaired. Tested offline (`tools/offline/t_make_v1.lua` makes a v1 file with main's own code, then `t_archive.lua`).

### Live test (2026-10-18, Vivace Ardente track, AI driving)
Old = main's analysis on the same recorded session.

| | Hirochi (3.9 km) | WCUSA Redwood/junction (2.1 km) | Italy mountain village (1.3 km) |
|---|---|---|---|
| review (save + analyse + send) | 0.15 s | 0.05 s | 0.11 s |
| payload | 311 KB (965 pts, 5021 trace) | 183 KB | 119 KB |
| grip used, new / old | 0.97 g / 1.72 g | 0.87 g / 1.72 g | 1.17 g (+7% aero at 150 km/h) / 1.72 g |
| gap, new / old | 13.9 s / 43.5 s | 4.5 s / 20.7 s | 24.3 s / 34.1 s |
| line steps through static geometry, new / old | 0 / 0 | 0 / 0 | 1 / 6 (the 1 is where the AI stopped against a wall) |

- Sampling ran at 62.6 Hz. The car info arrived: 1454 kg, 257 kW, AWD, ABS, brakes up to 1.86 g.
- Old grip: the old model's 1.72 g came from the coach's learned grip, which only ever rises and was probably set by crash spikes. It made every gap heroic.
- Italy: the old line ran along the top of the low stone garden wall in the village hairpin; the new one keeps car-width clearance (32 points moved by the clip check).
- Found live and fixed:
  - Sparse samples after an analysis were saved as JSON objects with string keys, so `loadLast()` failed on the reloaded file. This also affects main. `saveSession` now writes only the recorded fields, and `loadLast` repairs old files.
  - A junction kink in the line (median on the edges).
  - Forest roads taken for circuits (auto style).
- The test helpers' wall check must take heights from the recorded samples: a probe from above lands on bridges (Hirochi overpass) and the redwood canopy. The mod itself probes down from the car's height.

## G. Slope, crests and banking (2026-10-18)
- **Measurements:** `addAccelerations` adds `TLON` (field 23), the tyres' longitudinal acceleration: measured `LON` + g·grade, with grade = vz/|v|. It also adds `NF` (24), the vertical load factor 1 + a_z/g. The car model uses `TLON` for braking peaks and the full-throttle acceleration bins, and divides cornering and braking peaks by `NF`, so a downhill braking zone or a compression no longer skews the car's limits.
- **Terrain along the better line (`terrain(g)`):**
  - ground height under the line from short rays down
  - grade over ±1 point
  - vertical curvature over a ±3-point (12 m) stencil (+ = compression, − = crest)
  - bank toward the corner's inside, from the ground 1.5 m either side
- **Speed model:**
  - vertical load nf(v) = cos(slope) + v²·κv/g
  - cornering available = grip · nf + g·sin(bank toward the inside); the corner speed is solved by iteration, because both aero and crests depend on v
  - acceleration = engine/traction · min(1, nf) − g·grade
  - braking = brake limit · nf + g·grade (uphill helps)
  - the ideal pedal traces use the tyres' share (gravity's part removed)
- Corners carry `gradePct`, the average grade from the ideal brake point to the apex. The panel shows "6% downhill" and the engineer gets it as `brakeZoneGradePct`.
- **Offline test:** `tools/offline/t_slope.lua` (`MODE=flat|down|up`) is the t_walls corner with an 8% approach. Uphill moves the ideal brake point one grid step later. Downhill matches flat at 4 m grid resolution for this short zone, and the downhill car model is otherwise the same.
