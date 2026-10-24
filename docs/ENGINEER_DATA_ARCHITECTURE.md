# Race engineer data architecture

Written 2026-10-19 (Part B of `docs/archive/NEXT_PHASE_BRIEF.md`). **This is a design, not implemented.** It covers how telemetry becomes the structured, bounded data the Haiku engineer pulls through tools, while every real-time cue stays deterministic and works without Haiku.

## 1. How it works today (verified in code)

```
vehicle VM                          game engine (GE Lua)                        bridge (tools/engineer.py)          Claude API
coDriverRec.updateGFX ~60 Hz  --0.5 s batch-->  coDriverAnalysis.onChunk (samples in RAM,
  sample(): 19 fields                            archived as session JSON)
coDriverRec.sendStatus 1 Hz   --serialize--->   coDriverEngineer.onStatus -> alerts (local rules)
                                                coDriverEngineer.ask():
                                                  driveContext() / reviewContext()  --req_*.json-->  answer():
                                                                                                    focus_drive() trims drive data
                                                                                                    haiku(system, msgs) ------------> Messages API
                                                  <------------------------------- res_*.json ---  (thinking disabled, 110 tokens)
```
- **Drive questions:** `coDriverEngineer.lua` `driveContext()` sends the whole car summary, weather, drive stats and grip with every question. The bridge narrows it (`tools/engineer.py` `focus_drive`) to the topics asked about, warm ranges, problems and a note. That's about 0.6–1 KB per request, with 6 turns of memory over 3 minutes **[verified]**.
- **Review questions:** `reviewContext()` sends the whole trimmed analysis: every corner with about 20 fields, plus tips and totals. For a 43-corner session that's roughly 15–25 KB of JSON in the **system prompt on every question** **[verified structure; size estimated]**. That's the main cost and latency driver, and it grows with the number of corners and laps.
- **Rules that are already deterministic** (alerts for fade, puncture, overheating, fuel and engine damage; warm-up and problem detection) run locally in `coDriverEngineer.lua` `checkAlerts` and `tools/engineer.py` `car_problems`/`offline_drive` **[verified]**.
- **No tool use yet:** Haiku gets context pushed to it **[verified]**.

## 2. Target architecture: four data tiers

| Tier | What | Where computed | Rate | Ever sent to Haiku? |
|---|---|---|---|---|
| **T0 raw** | 60 Hz samples (position, velocity, inputs, brake ratio, load, surface) | vehicle VM, then GE | 60 Hz | **Never** |
| **T1 live state** | Speed, current and next corner (from the coach's notes), brake state, car condition (1 Hz), conditions (weather/time) | GE (`coDriverCoach`, `coDriverEngineer`) | 1–10 Hz | Through tools, as small snapshots |
| **T2 events** | Corner passed (entry/min/exit speed against target, brake point, incident), alert raised or cleared, lap started/completed/invalidated, off-road, crash, reset | GE, detected locally | when they happen | Through tools, as a ring buffer (last 50) |
| **T3 analysis** | Session, laps, sectors, corners, habits (post-drive model results) | GE `coDriverAnalysis` (after the drive) | per review | Through tools, one object at a time |

**Rule:** Haiku only ever sees **T1 snapshots, T2 event slices and T3 objects**, through bounded tool results of about 1.5 KB or less each.

### 2.1 Getting the data to the bridge (avoid game round trips)
A tool call shouldn't wait on the game, because file round trips cost 50–150 ms each **[hypothesis; 50 ms bridge poll plus the game's poll on pending requests]**. Instead:
- **Live snapshot:** while the bridge is online, GE writes `engineer/live.json` **every 1 s** with T1 state, the T2 event ring and freshness stamps. It's about 2 KB, written atomically (tmp + rename, which already exists). GE skips the write when nothing changed.
- **Analysis snapshot:** on Review, or when a session or lap is loaded, GE writes `engineer/analysis.json` with T3 objects keyed by id. It's written once.
- **Tools run locally in the bridge** from those two files. Only a "refresh now" tool goes back to the game, and that's rarely needed.

## 3. Tool specifications

These are Anthropic tool-use (function-calling) definitions inside the bridge. The same functions could also be exposed as an MCP server for development, but the in-game engineer doesn't need MCP **[design choice: one process, no extra hop]**.

Every result has this shape:
```json
{"ok": true, "data": {...}, "age_s": 0.8, "source": "live|analysis|rules", "confidence": "measured|estimated|unavailable", "note": "optional"}
```
Errors look like `{"ok": false, "error": "no_data|stale|not_simulated|unknown_id", "detail": "..."}`.

| Tool | Args | Returns (bounded) | Tier |
|---|---|---|---|
| `vehicle_condition` | — | damage level and parts (top 3), engine water/oil and problems, fuel %, and wheels broken or flat | T1 |
| `brakes_tyres` | — | brake temperature front/rear and fade %, a cold/in-window/hot verdict from ranges, tyre pressures and flats, and `tyreTempSimulated` (true/false) | T1 |
| `driving_conditions` | — | time of day, air temperature, sky, rain/fog/wind (with "rain is visual only"), surface under the car | T1 |
| `current_road` | `ahead_m` (≤400) | current speed; the next 1–3 pacenotes (call, distance, target speed, grade); whether on route | T1 |
| `recent_events` | `kind` (corner, incident, alert, lap, or all), `last_n` (≤10) or `last_s` (≤300) | newest-first events with times and key metrics | T2 |
| `session_summary` | `session` (default current/last) | time, km, gap to the better line, gap without incidents, top 3 losses (id, loss, short note), top 3 strengths, habit tips | T3 |
| `lap_list` | `session` | per lap: number, time, valid, delta to best, sector times (once laps exist) | T3 |
| `lap_compare` | `lap_a`, `lap_b` | lap times; the 3 biggest mini-sector stretches by rate, with owner and gain; corners where they differ most (brake point, min speed, exit) | T3 |
| `corner_detail` | `corner_id`, `lap` (optional) | that corner's measured metrics against the model, the note, positives, incident flag, grade %, radius | T3 |
| `driver_habits` | `sessions` (≤5) | recurring issues across recent sessions, with counts and trend (better, same, worse) | T3 + a profile file |

**Bounds:**
- At most **2 tool rounds per drive question** and **4 per review question**.
- Each result is ≤1.5 KB, enforced by truncation with `"truncated": true`.
- Drive mode only offers the T1 and T2 tools, plus `session_summary`.

## 4. Data schemas and relationships

```
Session 1--* Lap 1--* SectorTime        (laps only exist once a route is recognised)
Session 1--* CornerPass *--1 Corner      (Corner = a place on a route; CornerPass = one drive through it)
Session 1--* Event                        (T2, time-ordered)
Route   1--* Corner, 1--* Sector, 1--* Checkpoint
```

```jsonc
// Route: a repeatable road section, discovered or confirmed (see PROJECT_REVIEW.md §5.1)
{"id": "wcusa-r3", "level": "west_coast_usa", "closed": true, "length_m": 2540,
 "polyline": [[x, y, z], ...],            // every 4 m, the reference line
 "start": {"pos": [x, y, z], "normal": [nx, ny], "halfWidth": 6},
 "checkpoints": [{"s": 100, "pos": [x, y, z]}, ...],  // every 100 m
 "sectors": [{"id": 1, "s0": 0, "s1": 840}, ...], "corners": [{"id": 1, "s": 212, "dir": "right", "radius": 19}],
 "created": "2026-10-19T02:10:00Z", "source": "auto|manual|official"}

// Lap
{"route": "wcusa-r3", "session": "20261018_202533_...", "n": 2, "t0": 84.2, "time": 83.6,
 "valid": true, "invalidReason": null, "sectors": [27.9, 28.4, 27.3], "best": false}

// CornerPass (per lap or session pass)
{"corner": 4, "lap": 2, "loss": 0.44, "entry": 68, "min": 65, "idealMin": 68, "exit": 71,
 "brakeDiffM": -16, "brakeRiseS": 0.3, "coastS": 0.0, "incident": false, "gradePct": 9,
 "positives": ["Brake point on the mark"], "note": "Room to brake 16 m later."}

// Event (T2)
{"t": 249.1, "kind": "incident", "what": "spin", "corner": 43, "speedDrop": 46}
{"t": 120.4, "kind": "alert", "what": "brakes_fading", "value": 22, "cleared": false}
{"t": 168.0, "kind": "lap", "what": "completed", "lap": 2, "time": 83.6, "valid": true}
```
**Migration:**
- Sessions saved today (format 2, `sessions/*.json`) already contain everything needed to rebuild laps and corner passes offline.
- New files: `routes/<level>.json` and `profile.json`. Each has a `version` field.
- Older sessions without laps show "session" scope only.

## 5. Context and memory strategy
- **System prompt:** persona, radio or review rules, tool list. No data **[changes today's review mode, which embeds the whole analysis]**.
- **Per question:** the question, plus a ≤300-byte "situation line" assembled locally, e.g.:
  ```
  mode=drive; speed=72 mph; on route wcusa-r3 lap 3; last event: corner 12 passed -0.3 s
  ```
  Haiku then pulls the rest through tools only if it needs to.
- **Radio memory:** the last 3 exchanges within 3 minutes (as today). Tool results from earlier turns aren't replayed; their summaries are.
- **Review memory:** the last 6 exchanges per loaded session or lap scope, cleared when the scope changes.
- **Long-term memory:** `profile.json`, recurring habits and personal bests per route and car, updated locally after each review. Haiku only sees it through `driver_habits`.
- **Thinking stays disabled** for drive mode. Review mode may use a small thinking budget (`budget_tokens` ≈ 1024, with `max_tokens` raised to match), since review isn't time-critical. The default currently eats short budgets **[verified 2026-10-18: stop_reason=max_tokens with empty text]**.

## 6. Deterministic first, Haiku second
| Question type | Handled by | Why |
|---|---|---|
| "Brakes?", "fuel?", "damage?", "tyres?" | **Local template**, no LLM (`offline_drive` already exists) | Instant, free, exact. Haiku only rephrases if variety is wanted (optional) |
| Radio check, garbled input | Local ("Loud and clear." / "Say again?") | No API call needed |
| Alerts (fade, puncture, overheat, fuel) | Local rules (`checkAlerts`) | Must work offline |
| "Am I ready for a good run?", "how was that corner?", "where am I losing time?" | Haiku with T1/T2 tools | Judgement and phrasing |
| Debrief, "why was corner 5 slow?", lap comparisons | Haiku with T3 tools | Interpretation and coaching |

Local intent classification already exists in rough form as keyword topics (`topics_of`). The proposal is to route simple status questions straight to the template, cutting about half of drive-mode API calls **[hypothesis; to be measured with a question log]**.

## 7. Example queries and the tool calls they'd make
| # | Driver says | Mode | Tool calls | Expected answer shape |
|---|---|---|---|---|
| 1 | "Brakes?" | drive | none (local template from `live.json`) | "Good, 320 front, no fade." |
| 2 | "Am I ready for a good run?" | drive | `brakes_tyres` | "Yes, brakes are in the window, tyres grip from cold here." |
| 3 | "What's the next corner like?" | drive | `current_road(300)` | "Right three in 180, about 45, crest after." |
| 4 | "How did I do in that last corner?" | drive | `recent_events(kind=corner, last_n=1)` | "Lost 0.3, a touch early on the brakes." |
| 5 | "Why do I keep spinning?" | drive | `recent_events(kind=incident, last_s=300)`, `brakes_tyres` | "Two spins on throttle in slow rights; ease the pickup." |
| 6 | "Give me the debrief." | review | `session_summary` | 60–90 words, biggest time first |
| 7 | "Why was corner 5 slow?" | review | `corner_detail(5)` | Metrics against the model and one action |
| 8 | "Compare my last two laps." | review | `lap_list`, `lap_compare(n-1, n)` | Where the time went, by stretch |
| 9 | "Am I getting better at braking?" | review | `driver_habits(5)` | Trend from the profile |
| 10 | "Was the crash my fault?" | review | `recent_events(kind=incident)` or `corner_detail(43)` | Speed drop and context, no blame invented |
| 11 | "What lap time could I do?" | review | `lap_compare(best, ideal)` | Ideal lap from best sectors |
| 12 | "How are the tyre temps?" | either | `brakes_tyres` → `tyreTempSimulated: false` | "Tyre heat isn't simulated on this car; they grip from cold." |

## 8. Freshness, confidence and errors
- **Freshness:** every T1 field carries `age_s`. If `live.json` is over 3 s old, tools return `stale`, and Haiku must say "I've lost telemetry". Over 10 s, the bridge reports the game as offline.
- **Confidence:**
  - `measured`: read from the car (temperatures, fuel, damage).
  - `estimated`: model output (ideal speeds, grip).
  - `unavailable`: e.g. tyre temperature when `tyreTempSimulated=false`.
  - **Haiku must label estimates** ("about", "the model says") **and never fill in unavailable values.** That goes in the system rules, and the result schema enforces it.
- **No invention:** if a tool returns nothing, the answer says so. The bridge rejects (re-asks once) any answer containing a number that isn't in the tool results or the situation line **[proposed check: regex numbers ⊆ provided numbers ±rounding]**.
- **Timeouts:** 6 s for drive questions, then the local template answer with source "offline". 25 s for review. Retry once on 5xx or 529.
- **API failure:** the deterministic answer always exists for drive mode. In review mode, `offline_review` gives the top losses and tips.
- **Malformed tool calls** (unknown id, bad args): return an error object; Haiku apologises briefly or asks.
- **Budget guard:** log tokens, latency and tool calls per question to `engineer/usage.jsonl` for the cost report (Phase 7).
