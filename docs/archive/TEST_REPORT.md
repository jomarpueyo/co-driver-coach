# Co-Driver Coach: unattended test run, 2026-10-17 (6:49–7:20 PM)

The game's AI drove every scenario through BeamNG's built-in MCP server. Your settings, drive history and learned grip were backed up first and restored afterwards; they're verified unchanged.

## Scenarios

| Scenario | Drive | Grade | Notes |
|---|---|---|---|
| Italy, Vivace track (aggressive AI) | 3:12, 3.0 mi, 16 corners, up to 187 km/h | A- | Commitment F (the AI took corners at 66% of *your* learned 1.31 g targets) |
| West Coast USA, ETK 800 | 1:46, 0.3 mi | F | The AI hit the first square junction at 117 km/h, crashed twice and crawled; the grade was accurate |
| West Coast USA, GPS route (~1.2 km) | 2:21, 1.9 mi, 15 corners | A | The coach followed the GPS route 100% of the time |
| Utah, pickup on dirt and hills | 3:40, 2.3 mi, 21 corners | A- | Called crests and big crests; Commitment F at 67% of the 0.9 g default |
| Johnson Valley, pickup off-road | 2:48, 1.1 mi, 6 corners | A+ | The trails are in the road graph, so it stayed "on road" with calls throughout |

## Edge cases, all passed
- **Pressing END with no real drive** shows the "No drive in progress yet" message.
- **A reset mid-drive** counted 1 reset and the drive carried on.
- **Every toggle** (on/off, voice, style, surface ×3) went round and back with settings restored exactly.
- **Voicepacks** dirtwheel (232 clips), rh (180) and ak (181) all load. **fluffy** has only 12 clips (no numbers, no "brake").
- **Switching cars mid-drive** made the coach follow the new car with default grip. Removing it restored your Vivace's learned 1.31 g.
- **Errors:** none from the coach in any scenario. Errors that did appear came from the game itself: its stock drag-race app, and screenshot bookkeeping triggered by MCP screenshots.

## Performance
- **Game Lua time per frame** was 0.32 ms with the coach off and 0.36–0.45 ms with it on, so it costs well under 0.1 ms per frame.
- **Building the map view** takes 0.05 ms per call.

## Fixes applied after the run
1. **Commitment** now gives full marks from 95% of the target, then −1 point per %. The old curve gave moderate drivers an F at ~67%.
2. **Tarmac default grip** is lowered from 0.90/0.85 g to 0.80/0.80 g, which fits ordinary cars and trucks. Fast cars still learn higher grip from your driving.
3. **Voicepacks** that can't say the current call style or "brake" are skipped (that's fluffy).
4. **Calls link at most two corners** ("3 Left and 4 Right") instead of three, so they stay short and on time.
5. **No "long" on hairpins or squares**, so "Tight hairpin Left long" no longer happens.
6. **The map skips labels** that would overlap another.

## Not fixed: ideas for next time
- **Auto-detect the surface.** The button stays on TARMAC while you're on dirt; the coach could read the ground under the tyres and switch itself.
- **Map labels** could be placed beside the line instead of being skipped when crowded.
- **AI-only testing** can't check the voice or how the grades feel for a human driver. Your real drives will.

Raw results: `%TEMP%\cdc_tests\results.jsonl`, with screenshots in your BeamNG `screenshots\mcp` folder.
