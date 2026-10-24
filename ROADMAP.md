# Co-Driver Coach: status and what's next

Updated 2026-10-20. `README.md` describes every feature for players; `DEV_CONTEXT.md` has the developer
notes; `docs/PROJECT_REVIEW.md` has the measured performance and the original prioritised plan.

## Where it stands
- **Co-driver:** corner calls in a rally voicepack (the game's, or your own 120 recorded clips), brake cues with a filling bar and an
  optional braking zone on the road, slide hints, crests, distance calls, the navi-screen map, practice
  scenarios with GPS stages, an end-of-drive debrief with grades.
- **Drive analysis:** 60 Hz telemetry, a better line clear of walls, an ideal speed profile from a model of
  your car (learned grip, aero, brakes, power, slope and banking), corners ranked by time lost, turn-by-turn
  replays with both lines in 3D, incidents kept out of the coaching.
- **Laps:** automatic loop and point-to-point recognition, lap timing with sector splits and a live delta,
  per-lap review (best lap, sectors, theoretical best, turn-by-turn bests, any two laps compared).
- **Race engineer:** push-to-talk with Whisper (pre-roll, cleaned audio, learned fixes from your
  corrections), Haiku answers that stick to what you asked, car adjustments by voice, spoken lap times,
  lap-aware debriefs, a voice log with a review page.
- **Settings:** everything in one panel (⚙ on the strip or a hotkey). Replay recording off / laps only /
  always; nothing is ever deleted automatically.

## Needs you (can't be tested without a driver)
- **Validation drives on the wheel:** corner rules and thresholds, smoothness and commitment scoring, and the
  braking aid were tuned on AI driving. A few real drives on the loop and a mountain road would settle them.
- **Your voice through Whisper:** talk to the engineer for a session, then open `tools\voice_review.bat`
  and mark what it got right or wrong. Two corrections of the same mishearing become an automatic fix.
- **Voice clip check:** 79 of the 120 clips were confirmed by speech recognition; listen to the rest
  (`coDriverCoach.say({'word'})`) and re-record any that sound clipped (`tools/voicepack/`).
- **Stage finish:** pass detection and backwards-route rejection need one real stage drive.

## Next features (ordered by value)
The research-driven work (mini-sector stretches, engineer tools, official courses, personal bests and a
ghost, balance line, recce) is phased in `docs/PLAN_FROM_RESEARCH.md`; the items below are the rest.

1. **Whisper small.en option:** more accurate than `base.en` but about 2-3 times slower on the CPU; worth
   measuring once there's a voice log of real questions to compare on (`whisper` in engineer_config.json).
2. **Compare across sessions:** today's best lap against last week's on the same route (routes are saved per
   level, sessions keep their laps), and a ghost car (`ai.startFollowing`).
3. **Junction choice without GPS:** `graphAhead` takes the straightest branch; use the turn signal,
   steering or heading change to pick the branch.
4. **Auto surface for the calls:** the analysis already reads the surface under the tyres; let the coach
   switch tarmac / gravel / snow grip by itself and say "onto gravel".
5. **Use recorded lines the coach doesn't say yet:** countersteer, flat out, keep left / right, narrows,
   bumpy / slippy (some need road-width or surface data).
6. **Engineer:** answer simple status questions locally (no Haiku call), hold engineer lines while a
   pacenote plays, optional GPU Whisper.
7. **Analysis extras:** level minimap image under the map, a G-G plot, a balance-coloured line, official
   time-trial routes preloaded as routes.
8. **Recce mode and scenario leaderboards.**
9. **Measure the remaining navi-screen cars** (`tools/measure_cars.py 'model:config'`, parked).

## Code health
- `coDriverCoach.lua` is at 182 of LuaJIT's 200 top-level locals (scenarios moved to
  `coDriverCoach/scenarios.lua`); the screen section and the voice queue are the next candidates.
- Offline tests cover the analysis, laps and lap analysis (`tools/offline`); the coach's road analysis and
  grading have none yet (they need map mocks).
- A packaging script for a mods-folder zip, with a build without the personal voicepack for sharing.
- The constant static heard early on was in the game's audio engine (FMOD near 100% DSP with the coach off);
  recheck `Engine.Audio.getAudioStats().cpuDsp` if it comes back.

## Reference
- **Installed mod:** `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\co_driver_coach` (`tools/deploy.sh`).
- **Settings and data** (`settings/` in that user folder): `coDriverCoach.json` (coach), `coDriverCoach_cars.json`
  (learned grip), `coDriverCoach/` (analysis and lap settings, sessions, routes, engineer, voice log),
  replays in `replays/codriver/`.
- **Backups:** `Documents\BeamNG_CoDriver_Backups\<stamp>` before any test that touches recordings.
- **Test setup:** UI scale 1.5 with unlimited UI resolution, driver FOV 36°, a wheel and pedals.
- **Game MCP server:** `http://127.0.0.1:29292/mcp` (Options → enable MCP); `tools/bmcp.py` calls it.
