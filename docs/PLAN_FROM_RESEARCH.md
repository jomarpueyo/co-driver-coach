# Plan from the research findings

Written 2026-10-20. Turns `docs/EXTERNAL_PROJECT_RESEARCH.md` (seven BeamNG timing, telemetry and rally projects)
and `docs/ENGINEER_DATA_ARCHITECTURE.md` (the engineer's data and tool design) into phased work, checked
against what is already built (`ROADMAP.md`, main at 98a3358). Phase C is implemented (see its section); the rest is not yet.

## 1. Where the research recommendations stand

| # | Research recommendation (§6 order) | Status | Gap |
|---|---|---|---|
| 1 | Lap recognition: gate, route progress, validity rules, checkpoints, manual start | **Done** (`coDriverLaps.lua`) | Heading comes from velocity, not a 12 m path tangent; fine so far |
| 2 | Reference-lap alignment and mini-sectors (ghost-racer-telemetry) | **Done** (Phase A, 2026-10-20: 10 m cells, ownership, flicker merge, stretches ranked by rate, 10 m theoretical best, panel list and map mode, engineer context) | Not yet checked in game |
| 3 | Engineer tools over lap and sector data | **Done, measured** (Phase B, 2026-10-21: local answers 65% of drive questions, event ring, reply and number checks; review tools built and measured, off by default) | Review tools cost more than the cached full analysis |
| 4 | Official quick race and time trial layouts as known routes | **Done** (Phase C, `coDriverLaps/courses.lua`; settings list in Phase D) | Only West Coast USA checked in game |
| 5 | Balance-coloured line and measured power (BeamLap) | **Done** (Phase E, 2026-10-21: per 4 m point understeer / oversteer, map mode, corner notes, engineer; power at the wheels) | Thresholds want a few more of your drives; measured power is 77-83% of the listed crank figure (drivetrain and drag), not within 15% |
| 6 | Recce pacenotes and engineer lines in your voice (rallymodemod idea) | **Done** (Phase F, 2026-10-21: recce per route, three AI runs gave the same calls; lines fully covered by your 120 clips play in your voice) | Few engineer lines are fully covered by pacenote words |
| 7 | Visual-only ghosts (Ghost Racer Enhanced idea) | **Done** (Phase D, 2026-10-21: best lap kept per route, best-ever compare, marker and 200 m line, 0.04 ms a frame) | |
| — | Adaptive telemetry rate (30 Hz cruising, 60 Hz near corners) | **Not started** | Only worth it if frame time becomes a problem |

## 2. Ground rules for all phases
- **Licences:** reimplement from the descriptions; copy no code. ghost-racer-telemetry is MIT, so if any code is
  ported verbatim, add `THIRD_PARTY_NOTICES.md` with its copyright line. Ghost Racer Enhanced, AutoChrono and
  BeamLap are ideas only; rallymodemod is GPL-3.0 and must not be copied.
- **Performance budget (measured 2026-10-20):** the extensions cost microseconds a frame; the replay recorder
  (1.3-1.9 ms) is the only big item. A file write on the game thread costs about 1.1 ms, so nothing new may write
  files every second while driving.
- **Testing:** offline tests in `tools/offline` for every algorithm, a live AI drive on the saved loop for
  anything that runs while driving, and backups before any test that touches recordings.
- **Needs you:** wheel validation drives and voice corrections can't be automated; each phase lists what
  would benefit from a real drive.

## 3. Phases

### Phase A: "Where the time is" (mini-sector stretches) · about 1 session · highest value
**Why:** today's review says *which* lap and turn lost time; ghost-racer-telemetry's method says *exactly where*,
in a form the driver can act on ("you lose 0.4 s in the 120 m after turn 6 exit").
- Time every lap over **10 m cells** along the best lap's stations (the projection already exists in `lapAnalysis`).
- **Ownership:** the quickest valid lap owns each cell. **Flicker merge:** runs shorter than 3 cells between one
  other owner are merged. **Drop** stretches under 0.02 s total or 0.01 s per 100 m. **Rank by rate** (s per
  100 m), so a short, sharp gain beats a long, mild one.
- **Outputs:** `laps.stretches` (top 8 per lap: from-to metres, nearest turn, gain against the best lap, rate);
  a theoretical best from 10 m cells (more precise than today's 50 m).
- **Panel:** in lap and compare views, a "where the time is" list; clicking one zooms map and charts to it.
  A map colour mode by owner lap in compare view.
- **Engineer:** stretches added to the lap context, so "where did lap 4 lose time?" gets places, not just turns.
- **Accept:** offline on the 7-lap session: the sum of a lap's stretches against the best lap is within 0.1 s of
  its gap; ranking order is stable; theoretical best no slower than the 50 m one.

### Phase B: Engineer tools, the lean version · about 1.5 sessions · **done 2026-10-21** (results in `DEV_CONTEXT.md`)
**Why:** the design in `ENGINEER_DATA_ARCHITECTURE.md` cuts tokens and invented numbers. One change to the
design, based on the 1.1 ms write cost: **don't write `live.json` every second.** The game already sends the
drive context with each question; the tools run in the bridge **over that payload**, and the analysis goes to
`analysis.json` once per review.
- **Local answers first:** "brakes?", "fuel?", "damage?", "tyres?", "speed?", "last lap?", radio checks, and
  low-confidence speech get template answers with no API call (`offline_drive` exists). Measure the share with
  the voice log; target at least 40% of drive questions answered locally.
- **Event ring (T2):** the last 50 events (corner passed with its loss, incident, lap, alert) kept in GE and sent
  with each question, so "how was that corner?" works mid-drive.
- **Tools** (bounded to 1.5 KB each, at most 2 rounds in a drive and 4 in a review): `recent_events`,
  `session_summary`, `lap_list`, `lap_compare` (with Phase A stretches), `corner_detail`, `brakes_tyres`.
- **Number check:** any number in an answer that isn't in the data (within rounding) makes the bridge ask once more.
- **Review:** a small thinking budget (about 1,024 tokens) for debriefs only.
- **Accept:** a 30-question set (taken from your voice log where possible) with no invented numbers; drive answers
  p50 1.0 s or less; review input tokens down at least 50% against today's 7.3k cached prompt.

### Phase C: Official courses as routes · about 1 session · **done 2026-10-20**
Built as planned, plus `.race.json` layouts. Live: 22 West Coast USA courses load; AI laps on Street Course 2
forward (2:34.380) and reverse (3:07.901), each with 6/6 checkpoints. Open: the settings panel row
(`getCourses`/`setCourseEnabled` are ready), and checking other levels in game. Details in `DEV_CONTEXT.md`.
**Why:** BeamLap's insight: the game ships proper courses. Importing them gives timed laps on day one on any map,
with real names, and avoids discovery errors.
- Read `levels/<level>/quickrace/*.json` (name, closed, lap count, reversible, finish checkpoint, checkpoint list)
  and the checkpoint positions from the matching `_forward` / `_reverse` prefabs, through the game's file system.
- Build each route's line by following the road graph checkpoint to checkpoint (`map.getPath`), with gates at the
  start/finish checkpoint; save as `source: official` with the course name. Checkpoints come from the course.
- Settings list them separately ("official courses"), off by default per course so they don't all time at once;
  "time this course" turns one on.
- **Accept:** all 13 West Coast USA layouts load; AI drives one city race forward and one reversed, timed with
  every checkpoint passed; a free-roam drive that crosses a course without following it starts no lap.

### Phase D: Personal bests across sessions, and a ghost · about 1.5 sessions · **done 2026-10-21**
**Why:** today a lap can only be compared within its own drive. Keeping the best lap's telemetry per route makes
"against your best ever" possible and enables Ghost Racer's best feature without its cost.
- When a lap sets a route best, store a compact copy of that lap (4 m points: position, time, speed, throttle,
  brake, steering; about 40 KB) in `routes/<level>/<route>_best.json`, with car and date.
- **Review:** "compare with your best ever (date, car)" alongside the laps of the drive (reuses compare).
- **Live ghost (optional, off by default):** a small marker on the road where your best lap was at this lap time,
  plus the best line for the next 200 m only (the research warns against long ribbons). A frame-time check with
  `tools/perf_bench.sh` before it ships.
- **Engineer:** "am I faster than my best?" mid-lap uses the live delta (exists); in review, the best-ever lap is
  one more lap to compare.
- **Accept:** AI laps on the loop: a new best replaces the file, an older session compares against it, the ghost
  costs under 0.1 ms a frame.

### Phase E: Balance-coloured line and measured power · about 1 session · **done 2026-10-21**
**Why:** BeamLap's two cheap wins; both explain *why* a corner was slow.
- **Balance:** per 4 m point, understeer when steering is high for the curvature driven (steering ratio from the
  car's data, which the coach already learns as `steerGain`), oversteer when the slip angle exceeds a few degrees
  with countersteer. A map colour mode: red understeer, blue to green slide, grey neutral; per corner "pushed wide
  on entry" or "rear stepped out on exit" notes.
- **Measured power:** from full-throttle pulls (`carModel` already fits the acceleration envelope): power at the
  wheels against speed, shown in the car line of the model text and as a fact for the engineer.
- **Accept:** on AI drives, slides flagged where the AI spun; power within 15% of the car's listed figure.
  Thresholds want a drive with a wheel to settle.

### Phase F: Recce pacenotes and your voice for engineer lines · about 1.5 sessions · **done 2026-10-21**
**Why:** rallymodemod's recce model gives identical calls on every run, which real rally relies on.
- **Recce:** on a saved route or stage, "recce this route" records the calls the coach makes on a slow drive
  (text and position along the route); later runs on that route play those calls at the same places, with the
  call timing setting still applying. Calls can be cleared per route.
- **Your voice for short engineer lines:** greedy longest-match of a line's words to the 120 recorded clips; if
  every word is covered, play the clips, else use Kokoro. That suits short calls like "brake" or "careful";
  lap times and longer answers stay with Kokoro.
- **Accept:** two AI runs on a recced route produce the same call sequence; a line fully covered by clips plays
  in your voice.

### Phase G: Adaptive telemetry rate · about half a session · only if needed
- 30 Hz on straights, 60 Hz from 3 s before a brake point through the corner exit (the coach knows both).
- **Accept:** `perf_bench` shows a measurable gain; the analysis results on a re-recorded loop stay within noise.

## 4. Order and parallel work
Recommended: **A → B → C → D → E → F**, with G only if frame time becomes a problem.
- A first: it builds directly on the merged lap review and feeds B and D.
- A and C touch different files (analysis vs laps) and can run as two sessions at once.
- B needs A's stretches for `lap_compare`; D reuses A's compare plumbing.
- E and F are independent of each other and can run in parallel after D.

## 5. Decisions for you
- **Ghost (Phase D):** wanted at all, and as a marker or a line?
- **Official courses (Phase C):** time them only when you turn one on (recommended), or all at once?
- **Engineer local answers (Phase B):** fine for simple status questions to skip Haiku (faster, no variety)?
- **Whisper small.en:** worth trying once your voice log has a session of real questions to compare on.

## 6. Considered and left out
- **OutGauge / MotionSim UDP** (DriveLab, RacingDash): no position data, so it can't replace the recorder.
- **Online relay** (BeamLap): no online features planned; the file bridge covers the engineer.
- **Physical ghosts:** Ghost Racer's author calls them practically unusable; visual-only is the plan.
- **Road edges from level archives at runtime** (ghost-racer-telemetry): heavy; only as a cached, offline-built
  map background if the analysis map ever needs it.
- **Copying rallymodemod or Ghost Racer code:** licences don't allow it; ideas only.

## 7. Not from the research, still on the roadmap
Junction choice without GPS, auto surface for the calls, unused recorded lines (countersteer, flat out, keep
left/right), level minimap under the analysis map, a G-G plot, scenario leaderboards. See `ROADMAP.md`.
