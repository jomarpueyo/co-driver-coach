# External project research

Written 2026-10-19 (Part B of `docs/archive/NEXT_PHASE_BRIEF.md`). It compares seven BeamNG telemetry, timing and rally projects with Co-Driver Coach, and recommends what to adopt.

**Evidence labels:**
- **[source]**: read in the project's published source code (file and function given).
- **[readme]**: claimed in a README or product page, not seen in code.
- **[hypothesis]**: my inference.

Everything was read on 2026-10-19. Repos and pages change.

## 1. Comparison at a glance

| Project | What it is | Telemetry source | Lap / route model | Comparison | Licence | Reuse |
|---|---|---|---|---|---|---|
| [flintt/ghost-racer-telemetry](https://github.com/flintt/ghost-racer-telemetry) | Go + browser viewer for Ghost Racer Enhanced laps | Reads the mod's `ghostReplays` JSON files from the author folder **[source]** (`internal/ghost/scan.go`, `lap.go`) | Laps are defined by the mod's gates; the viewer only reads them | Reference-path projection, 10 m mini-sector ownership, ideal lap, delta **[source]** (`web/app.js`) | **MIT** | ✅ algorithms and code (with attribution) |
| Ghost Racer Enhanced ([resource 39196](https://www.beamng.com/resources/ghost-racer-enhanced.39196/)) | In-game ghost-lap mod by flintt, v2.19.8 | Records in game (position, time, speed; throttle/brake/gear/handbrake/clutch from 2.19.8) **[readme]** | Manual **directed gate**, then automatic laps; point-to-point finish gate; route checkpoints; track variants **[readme]** | Live Δt/Δv against the fastest ghost; visual-only ghosts **[readme]** | **None stated** | ⚠️ ideas only |
| [rpmn0ise/AutoChrono](https://github.com/rpmn0ise/AutoChrono) | Stopwatch + timing gate UI app | Vehicle electrics flags for hotkeys; GE position per frame **[source]** | One manual gate placed 8 m ahead; bounded-box side-change crossing with a 3 s cooldown **[source]** (`lua/ge/extensions/autoChronoGate.lua`, `onUpdate`). README also claims auto-recorded checkpoint tracks **[readme]**, not visible in the Lua. | Best and last lap only | **None** (all rights reserved) | ⚠️ ideas only |
| [beamlap.com](https://beamlap.com/features) | Hotlapping mod + online service (public beta) | In-mod recording of position, heading, steering, throttle and brake at about 10 Hz **[readme]** | Uses the map's own quick race and time trial layouts, forward or reverse, plus user-built courses; gate splits **[readme]** | Two-lap compare (speed/throttle/brake/steering/Δt), corner apex and minimum speeds, a line coloured by balance (understeer/slide), measured power from a full-throttle straight **[readme]** | Mod closed during beta; [relay](https://github.com/BeamLap/beamlap-relay) is **MIT** **[source]** | ⚠️ ideas; the relay pattern is reusable |
| [prokyle123/BeamNG-Android-Telemetry](https://github.com/prokyle123/BeamNG-Android-Telemetry) (DriveLab Telem) | Commercial Android dashboard | The game's built-in **OutGauge + MotionSim UDP**, with no mod **[readme]** | Not described | Drift Lab, drag and brake tests, achievements **[readme]** | **Proprietary EULA**; source not published (`SOURCE-NOTICE.md`) **[source]** | ❌ nothing to reuse but the idea |
| [lellolillili/rallymodemod](https://github.com/lellolillili/rallymodemod) | Rally mode with hand-authored pacenotes on Time Trial stages | Scenario waypoints and player position **[source]** | Pacenotes tied to scenario waypoints; stage start to finish | Not a comparison tool | **GPL-3.0** | ⚠️ ideas; copying code would make our mod GPL |
| [construktdev/BeamNGRacingDash](https://github.com/construktdev/BeamNGRacingDash) | Python dashboard over WebSocket | **OutGauge UDP** on port 4444, parsed with `struct` (92/96-byte packets) **[source]** (`telemetry/receiver.py`, `OutGaugeParser.parse`) | None | None (live gauges) | **Apache-2.0** | ✅ parser pattern, if we ever want OutGauge |

**What we already do that none of them do:**
- an ideal line and speed model from the driver's own grip (`coDriverAnalysis.lua`: `betterLine`, `idealSpeeds`, `carModel`, `terrain`)
- per-corner coaching rules with positives
- live pacenotes from the road graph rather than hand-authored notes
- a voice engineer

**What they do that we don't:**
- repeatable laps or courses in free roam (Ghost Racer Enhanced, AutoChrono, BeamLap)
- comparison against a reference lap (ghost-racer-telemetry)
- mini-sectors and an "ideal lap" (ghost-racer-telemetry)
- ghosts (Ghost Racer Enhanced)
- authored or recce pacenotes (rallymodemod)

## 2. Project notes

### 2.1 ghost-racer-telemetry (MIT): the most valuable source
- **Reference-path stations [source]** (`web/app.js`, `stationsFor` and `stationAt`, around line 1050):
  - Each sample of a lap is projected onto the *reference lap's* polyline with a windowed nearest-point search: from the previous index −4 to +64, widened by 256 when the best match sits on the window's front edge.
  - It then refines to the nearest point on the two adjacent segments.
  - It **forces the station never to decrease**, so stops, spins and reversing don't walk backwards.
  - The README measures the bias it removes: 16.6 m over a 2.3 km lap when the line is 3 m wide.
  - This is the right alignment for lap comparison, and our analysis already does something similar on its own driven grid.
- **Mini-sectors [source]** (`computeSectors` and `collectRuns`, constants at line 1022):
  - `SECTOR_STEP = 10` m cells, each timed per lap; the quickest lap owns the cell.
  - Runs shorter than 3 cells sandwiched between one other lap are merged away (flicker filter).
  - A stretch is dropped under 0.02 s total gain or 0.01 s/100 m.
  - Stretches are **ranked by rate (s per 100 m), not total**, so a short fierce gain beats a long mild one.
  - The ideal lap is the sum of the best cells.
- **Delta [source]** (`computeDelta`): the reference time interpolated at the lap's own distance. Note that this uses each lap's own distance, while sectors use the reference projection; we'd use the projection for both.
- **Gradient [source]** (`internal/ghost/lap.go`, `deriveGradient`): computed over a 10 m window of travel, not neighbouring samples, because suspension noise swamps the slope at 50 Hz. Our `terrain()` uses ±1 grid point (4 m) plus smoothing, which is comparable.
- **Heading from the path tangent [source]** (`pathHeadingAt`, a 12 m window widened to 40 m) rather than the car's facing. The README measured 0 reversals through a drift, against 18 using the car's facing. This is useful for map-up rotation and for direction-of-travel checks in lap recognition.
- **Real road edges [source]** (`internal/roads/roads.go`): reads `DecalRoad`/`MeshRoad` nodes `[x, y, z, width]` from the level archive's `items.level.json` and Torque prefabs.
  - It filters by `drivability`, keeps MeshRoads as bridges, welds gaps and caches per archive and build.
  - It's read-only on game files, which is allowed, but heavier than our road graph plus wall raycasts.
  - Keep it as an option for the analysis map background.
- **Licence:** MIT, so code can be ported with the copyright notice kept.

### 2.2 Ghost Racer Enhanced (no licence stated): best UX reference for free-roam laps
- **Directed gate:** "stop where you want it, point the car in the lap direction, Set & start lap" **[readme]**.
- **Lap validity rules:** crossings must be between the gate pillars, in the correct direction; very short laps, reverse crossings, vehicle resets and teleport-sized jumps are rejected, and the HUD shows why **[readme]**.
  - A reviewer reports the reverse-crossing rule wrongly cancels laps on tracks that double back near the gate (Tsukuba) **[readme]**. **Lesson:** check direction against the route tangent, not just the gate normal, and allow the route to pass near the gate.
- **Saved starts per map; route checkpoints; track variants** (several routes from one start); point-to-point finish gate; incomplete attempts kept by distance reached **[readme]**.
- **Ghosts are visual-only** (wireframe or static DAE mesh, no physics) for performance; the author says a full physical ghost is "practically unusable" **[readme]**.
- **Known limitation:** "crossings, overpasses and branching routes can occasionally confuse live route-position matching" **[readme]**. That's exactly the false-match risk our design has to handle (see `docs/ENGINEER_DATA_ARCHITECTURE.md` §4).
- **Licence:** none stated. Treat the code as off-limits; designs and ideas are fine.

### 2.3 AutoChrono (no licence)
- **Gate crossing [source]** (`autoChronoGate.lua`, `onUpdate`):
  - The gate is a plane through a point with a normal (the car's heading) and a right vector.
  - A crossing counts only when the car is inside a bounded box (±4 m wide, −1 to 3.5 m high) and its side flips; `lastSide` updates only inside the box.
  - A 3 s cooldown debounces it.
- **It redraws the gate every frame** with `debugDrawer` **[source]**. That's cheap, and the same approach as our replay ribbons.
- **README overreaches:** it claims auto-recorded checkpoint tracks (one every 15 m) with export and import **[readme]**, but the Lua in the repo is a single gate; they may be in `app.js` or unpublished **[hypothesis]**.
- **Licence:** none, so ideas only. The bounded-box crossing test is generic geometry anyway.

### 2.4 BeamLap (mod closed during beta; relay MIT)
- **Courses come from the map's own quick race and time trial layouts**, forward and reverse, so there's no detection problem for official courses **[readme]**. We could import those layouts as known routes too (the scenario/quickrace JSON on each level) **[hypothesis; rallymodemod reads them the same way]**.
- **Balance-coloured line** ("red where the car understeers, blue to green where it slides") and **measured power** from a full-throttle straight **[readme]**. We already compute slip and an acceleration envelope (`carModel`), so both would be cheap to add.
- **Relay [source]:** the mod talks to a localhost relay (`ws://127.0.0.1:29390`) that tunnels to the service over TLS, because "a BeamNG mod cannot reach the outside on its own". That's the same constraint our file-based engineer bridge solves.
- **Recording at about 10 Hz** is enough for laps and lines **[readme]**. That supports adaptive sampling for us (see `PROJECT_REVIEW.md`).

### 2.5 DriveLab Telem (proprietary)
- **No-mod telemetry** through the game's built-in **OutGauge and MotionSim UDP** outputs **[readme]**.
- Nothing to reuse: the source is withheld and the EULA forbids it **[source]** (`LICENSE.md`, `SOURCE-NOTICE.md`).
- **Relevant fact:** OutGauge is a zero-Lua-cost way to get a few channels out of the game, but it doesn't carry position, so it can't replace our recorder.

### 2.6 rallymodemod (GPL-3.0)
- **Pacenote triggering [source]** (`lua/ge/extensions/scenario/pacenoteHandler.lua`, `onPreRender`): the note at waypoint *i* fires when `dist(i) < posOffset + speed × timeOffset`, then a distance-to-next suffix is chosen with `getDistCall`.
  - Our `callAheadSec` lead is the same idea.
  - Theirs runs in `onPreRender` every frame; ours runs at 10 Hz.
- **Phrase to sample matching [source]** (`getPhrasesFromWords`): greedy longest-prefix match of the words against the co-driver's phrase library (`codriver.ini`), recursively; random sample variants; a play queue.
  - Useful for the "speak with the author's own clips" roadmap item.
- **Recce and authored pacenotes** on scenario waypoints, with options like `nosuffix`, `shortpause` and `nopause` **[source]**. This is the model for our "Recce mode" roadmap item.
- **Licence: GPL-3.0.** Copying code would make the distributed mod GPL. Reimplement from the idea instead.

### 2.7 BeamNGRacingDash (Apache-2.0)
- **OutGauge parser [source]** (`telemetry/receiver.py`): `struct.unpack_from` for the 92 or 96-byte packet (with or without ID), an asyncio UDP endpoint on 4444, and broadcasting JSON at 20 FPS to browsers (`core/controller.py`).
- **Relevant pattern:** throttling the UI to 20 FPS while the source runs faster. Our live UI pushes at 10 Hz, which is fine.

## 3. Reusable algorithms and patterns, and where they'd go

| # | Algorithm or pattern | From | Our integration point | Notes |
|---|---|---|---|---|
| 1 | Reference-path stations (windowed nearest point, monotonic) | ghost-racer-telemetry `stationsFor` (MIT) | New `laps` module in `coDriverAnalysis.lua`; also replaces own-distance alignment between laps | Port to Lua; O(n) with a moving window |
| 2 | 10 m mini-sector ownership, flicker merge, rate ranking, ideal lap | ghost-racer-telemetry `computeSectors`/`collectRuns` (MIT) | Lap comparison view, and the engineer's `lap_compare` tool | Thresholds 3 cells / 0.02 s / 0.01 s per 100 m to start with |
| 3 | Directed gate with a bounded box, side change and cooldown | AutoChrono / Ghost Racer Enhanced (ideas) | Lap recognition: start/finish detection, both automatic and manual | Validate direction with the route tangent, not only the gate normal |
| 4 | Lap validity rules (minimum length, reverse, reset, teleport jumps) with a visible reason | Ghost Racer Enhanced (idea) | Lap recognition | Our splitter already breaks on teleports and gaps (`splitSegments`) |
| 5 | Route checkpoints along the lap | Ghost Racer Enhanced / AutoChrono (ideas) | Route matching: a checkpoint every 50–100 m along the reference | Detects shortcuts and leaving the route |
| 6 | Heading from the path tangent over a metres-based window | ghost-racer-telemetry `pathHeadingAt` (MIT) | Direction checks, map rotation | Robust in slides and spins |
| 7 | Official quick race and time trial layouts as known routes | BeamLap / rallymodemod (ideas) | Route library: preload known courses per level | Read-only level JSON |
| 8 | Balance-coloured line (under/oversteer) and measured power | BeamLap (ideas) | Analysis map colour mode; `carModel` power | Our slip and lateral data exist |
| 9 | Greedy phrase to sample matching | rallymodemod (GPL idea) | Engineer speaking short lines in the author's recorded voice | Reimplement |
| 10 | Localhost relay for online features | BeamLap relay (MIT) | Only if we ever add online features; the file bridge works today | Not needed now |
| 11 | Visual-only ghosts (static mesh, no physics) | Ghost Racer Enhanced (idea) | Optional replay or live ghost | Our 3D ribbons are cheaper still |

## 4. Licences and compatibility
- **Portable with attribution:** ghost-racer-telemetry (MIT), BeamLap relay (MIT), RacingDash (Apache-2.0). Keep a `THIRD_PARTY_NOTICES.md` with copyright lines if code is ported.
- **Ideas only:**
  - Ghost Racer Enhanced: no licence, so copyright applies by default.
  - AutoChrono: no licence.
  - BeamLap mod: closed beta.
  - DriveLab: proprietary.
- **GPL-3.0 (rallymodemod):** don't copy code. The mod is distributed privately today, but GPL code would force the GPL on any public release.
- **Compatibility:**
  - All of these run beside our mod without conflict.
  - Ghost Racer Enhanced and our recorder would both sample the car (double cost) **[hypothesis]**.
  - Reading the Ghost Racer `ghostReplays` folder as an import source is possible and read-only.

## 5. Performance implications
- **Projection and sectors run after the drive** (O(laps × samples) with a moving window). In LuaJIT that's milliseconds for a few laps **[hypothesis, based on our 0.15 s for full analysis]**.
- **Live lap detection must be cheap.** One gate test per frame (a few dot products) plus a route-progress check against the reference polyline at 10 Hz with a moving window costs microseconds **[hypothesis]**.
- **Avoid:**
  - **Per-frame `debugDrawer` of long ribbons while driving**, which Ghost Racer warns about with many ghosts. Draw only the next 200–300 m.
  - **Full road extraction from level archives at runtime.** Do it offline or cache it, as ghost-racer-telemetry does.
- **Sample rate:** 10 Hz (BeamLap) or 20 Hz (Ghost Racer share codes) is enough for laps and lines. Our 60 Hz only helps pedal and steering traces, so consider 30 Hz while cruising and 60 Hz near corners. See `PROJECT_REVIEW.md`.

## 6. Recommended implementation order
1. **Lap recognition (gate + route progress)** using patterns 3, 4, 5 and 6, with automatic discovery plus a manual "set start here" like Ghost Racer's. This is the foundation for everything below.
2. **Reference-lap alignment and mini-sectors** (patterns 1 and 2, ported from MIT code with attribution) inside lap-based analysis.
3. **Engineer tools over lap and sector data** (see `docs/ENGINEER_DATA_ARCHITECTURE.md`).
4. **Known routes from official layouts** (pattern 7) and an optional road-edge background (ghost-racer roads, cached).
5. **Balance-coloured line and measured power** (pattern 8).
6. **Recce pacenotes and voice-clip engineer lines** (pattern 9, reimplemented).
7. **Ghosts** (pattern 11), only if wanted after laps exist.
