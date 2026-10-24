# Next phase brief: review and planning (saved 2026-10-18, before a context clear)

The author's request, condensed with nothing dropped. **Review and planning only: no production-code changes until the author approves.**

## Part A: Opus 5.5 project review (phases 1–8)
1. **Architecture review.** Cover:
   - GE vs vehicle Lua lifecycles
   - telemetry, UI refresh, the Python bridge and Haiku, MCP overhead
   - replay and sessions, data flow, error handling and recovery, coupling and duplicated work, race conditions

   Deliver an architecture diagram, a dependency map and a prioritised tech-debt register.
2. **Performance regression.** The author reports about 80 FPS before the live engineer and about 55 FPS after (12.5 ms to 18.2 ms frame time).
   - Build a reproducible baseline: same map, car, camera, graphics settings and driving.
   - Toggle and measure: vanilla; co-driver only; plus telemetry; plus analysis; bridge idle; engineer monitoring; Whisper active; TTS active; full system.
   - Capture average FPS, frame-time percentiles, CPU, memory and update-loop timings, separating sustained loss from inference spikes.
   - Deliver a report, a cost breakdown per component, root causes backed by evidence, ranked optimisations and a validation plan.
3. **Automatic free-roam lap and route recognition (design only).**
   - Return-to-route detection, same-direction validation, auto lap timing, deviation and invalidation, rejoin.
   - Avoid false laps at intersections, overlapping roads and short repeated segments.
   - Compare GPS with road-graph matching. Cover minimum distance and time, start/finish tolerance, partial laps, point-to-point and loops, and auto vs confirmed vs configurable discovery.
4. **Lap-based analysis (design).** Per-lap telemetry, lap and sector times, overlaying selected laps, braking/entry/apex/exit comparison, personal-best sectors, delta to a reference lap, line consistency.
   - Scope selector: best, latest, a chosen lap, two-lap compare, whole session. Map, charts, corner list and replay all follow the selected scope.
   - Old recordings must stay compatible.
5. **Visual braking aid (design).** A: a braking distance bar. B: a braking zone overlay. C: audio and text only (today).
   - Reuse the existing brake points and target speeds.
   - Configurable, low clutter, low render cost, handles consecutive corners.
   - Recommend where it lives: minimap, coach strip or the 3D world.
6. **UI and settings audit.** Inventory every setting across Lua, JSON, UI, key bindings and console; find missing controls, inconsistent defaults and settings that don't persist.
   - Group into: co-driver and navigation, voice and audio, driving assistance, race engineer, recording and analysis, performance and advanced.
   - Known issues: some settings are hidden; returning to the full map from the coach isn't discoverable; some features are console-only.
7. **Haiku engineer optimisation.**
   - Context: live vs historical data, no raw telemetry.
   - Narrow MCP-style tools: car condition, tyres and brakes, conditions, recent mistakes, current and upcoming corner, session, laps, corner analysis.
   - Memory and expiry; brief mid-drive replies with no repetition.
   - Reliability: timeouts, stale or missing data, never inventing measurements.
   - Measure latency, tokens, tool calls and cost; decide when local deterministic logic replaces the LLM.
8. **Roadmap.** For each item: priority, component, problem, evidence, solution, benefit, risk, validation.
   - Priority order: performance > UI and navigation defects > Haiku > lap and route > lap analysis > braking aid > architecture cleanup.

**Constraints:**
- Don't modify game install files; keep the official mod architecture.
- Don't interfere with player controls.
- Preserve telemetry and replays; don't break scenarios, navigation or calls.
- Keep per-frame work and cross-process traffic minimal; justify any new dependency.
- Keep AI inference out of game loops; provide migration plans for schema changes.
- Prefer incremental changes.
- Mark verified findings vs hypotheses; never invent profiling results or BeamNG APIs.

**Final output:** an executive assessment; architecture diagram; performance findings and measurement gaps; defects and debt; feature designs; Haiku strategy; roadmap; test and validation plan.

## Part B: external project research
Read the author's implementation first, then research:
1. https://github.com/flintt/ghost-racer-telemetry
2. https://github.com/rpmn0ise/AutoChrono
3. https://beamlap.com/features
4. https://github.com/prokyle123/BeamNG-Android-Telemetry
5. https://github.com/lellolillili/rallymodemod
6. https://github.com/construktdev/BeamNGRacingDash
7. https://www.beamng.com/resources/ghost-racer-enhanced.39196/

For each project:
- valuable features and algorithms, with source files and functions
- telemetry ingestion and storage, lap recognition and comparison
- performance-sensitive parts, compatibility with this project
- licence and reuse limits, and whether this project already does it

Mark source-verified findings vs README claims vs hypotheses.

Then design the integrated system:
- free-roam lap recognition, reference-lap-aligned comparison, sectors and corners
- local deterministic analysis, efficient MCP tools with structured data
- Haiku interpreting mistakes, conversational follow-ups, minimal FPS cost

**Hard rules:** Haiku never ingests raw 60 Hz telemetry, only bounded tool results. Real-time cues stay deterministic and keep working without Haiku.

**Deliverables:**
- `docs/EXTERNAL_PROJECT_RESEARCH.md`: comparison, key source links, reusable algorithms, integration points, licences, performance impact, implementation order.
- `docs/ENGINEER_DATA_ARCHITECTURE.md`: ingestion and processing architecture, MCP tool specs, data schemas, session/lap/sector/corner relationships, context strategy, example queries with the tool calls they make, freshness/confidence/error rules.

**No production-code changes. Present findings and ask for approval before implementing.**

## State at handoff (2026-10-18 ~21:10)
- main = 63fed5c (installed in the game, includes the continuous replay d02c7ed).
- Branch `claude/analysis-upgrade-d4e19c` has f6c3424: replay rotation without corrupt files, and incidents kept out of the coaching. It's being live-tested by the analysis session and is **not merged**; merge only with the author's OK.
- Known facts useful for Phase 2:
  - An earlier frame-time probe saw 58.5 FPS with the maximum frame at 18.3 ms while idle, which hints at a 60 FPS cap or vsync. **Verify the graphics frame limiter before blaming components.**
  - Whisper (2 threads) costs about 3 FPS while it transcribes, around 1 s per question.
  - Kokoro (4 threads) only runs in the analysis.
  - The `.rpl` recorder writes about 55 MB per minute.
  - coDriverRec sends 60 Hz samples to GE in 0.5 s batches.
  - The bridge polls the file folder every 50 ms.
- The analysis session ([local_b6317021…]) owns the analysis code. Don't edit the same files in parallel.

## Outcome (2026-10-19, overnight)
Both parts are done. **Plan only; nothing implemented, waiting for the author's approval:**
- `docs/PROJECT_REVIEW.md`: architecture, measured performance, defects register, feature designs, roadmap, test plan.
- `docs/EXTERNAL_PROJECT_RESEARCH.md` and `docs/ENGINEER_DATA_ARCHITECTURE.md`.
- **Headline measurement:** the engine `.rpl` replay recorder costs about 1.7 ms per frame while driving (about 15%) and about 1.15 ms parked. The extensions cost about 0.3 ms; Whisper and Kokoro bursts about 2.2 ms only while running.
- **Analysis branch** `claude/analysis-upgrade-d4e19c` at 4c2f45d (incidents, replay rotation, safe cleanup) is still unmerged.
