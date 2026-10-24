# Co-Driver Coach for BeamNG.drive

A rally-style co-driver for free roam. It reads the road ahead and:

- **Calls corners out loud** using the game's own rally co-driver voices ("three left tightens into five right", "hairpin right", "crest").
- **Shows braking cues**: "Brake soon", then "BRAKE" or "TOO FAST" with a target speed. It says "brake" if you haven't started braking yet.
- **Shows a shift light** when you drive a manual gearbox in realistic mode.
- **Warns about slides**: understeer and oversteer, with which way to countersteer.
- **Times your laps by itself** on loops it finds, routes you mark and the map's official courses, with a live delta, your best lap kept per route across drives, an optional ghost of it, and **recce pacenotes** that give the same calls on every lap of a route.
- **Reviews each drive** against a better line worked out from your own grip: time lost per corner and why, lap by lap with "where the time is" stretches, a comparison with any lap or your best ever, the car's balance (pushing wide or the rear stepping out) and its measured power, with corner replays.
- **A race engineer you talk to** (push-to-talk, Whisper and Claude Haiku): status questions answered instantly from the car's data, questions about your laps and corners, debriefs in the analysis, car adjustments by voice (brake bias, force feedback, drive modes and aids), alerts when something needs attention, and short lines in your own recorded voice.

It only reads game data and never touches your controls. Everything runs in single-player through the official mod system.

## Install

**Needs:**
- BeamNG.drive 0.40 or later.
- For the optional race engineer: Windows with Python 3.10–3.12, a microphone, and an Anthropic API key for Claude Haiku answers.

1. **Get the files:** download this repository (Code → Download ZIP, then unzip it) or clone it.
2. **Copy the mod:** put the `co_driver_coach` folder in your BeamNG user folder, at
   `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\co_driver_coach` (create `unpacked` if it isn't there).
   The folder must hold `lua`, `scripts` and `ui` directly.
3. **Start the game.** If the main menu warns that mods were switched off (it does after every game update), turn them back on.
4. **Add the panels:** in free roam, press Esc → **UI Apps** and add **Co-Driver Coach** (the strip at the top) and **Co-Driver Map**. Also add **Co-Driver Debrief**, **Co-Driver Analysis** and **Co-Driver Scenarios**. Those three stay hidden until they're needed, so they can go anywhere; full screen suits the analysis.
5. **Bind the keys** you want under Options → Controls → Bindings → Gameplay, in the **Co-Driver Coach** group:
   - review analysis;
   - talk to engineer (hold);
   - lap timing start and finish marks;
   - record replay for this drive.
6. **Optional race engineer:** see [Race engineer](#race-engineer-voice-questions-claude-haiku) below (`tools\engineer_setup.bat`, then `tools\engineer.bat`).

**Updating:** replace the `co_driver_coach` folder. Your settings, drives and laps live in the game's `settings/` and `replays/` folders, so they stay.

**Uninstalling:** delete the folder.

**Your data:** the coach keeps its files in `settings/coDriverCoach*` and `replays/codriver/` in the same user folder. Delete those to remove them as well.

## Use

1. Start BeamNG and drive on any map with roads. Calls start on their own.
2. Once added to your free-roam layout (see Install), the panels work like this. The Debrief panel stays hidden until a drive ends.
   - **Coach**: a compact strip at the top centre, close to your line of sight. It shows the next corner large, then the two after it, and one status line (a slide warning beats a brake cue, which beats the drive info).
   - **Map**: bottom right, beside the tacho (0.40's own minimap took the bottom-left corner).
   - **Debrief**: a centred two-column card, with grades on the left and the path to the next grade plus the focus card on the right.

   The layout engine only accepts pixel sizes. If your UI is much smaller than 1400×817, drag the debrief smaller in UI edit mode. To add them elsewhere: Esc → **UI Apps** → add them by name.
   - **Co-Driver Coach**: the next corners, distance, max speed, brake cue, slide hints and shift light.
   - **Co-Driver Map**: a top-down line drawing of the road the coach is reading. The car points up, corners are coloured by severity (red = slow, yellow = medium, green = fast, blue ring = crest), and a "B" bar marks where braking has to start.
3. If you set a GPS route on the big map, the coach follows it at junctions. Otherwise it follows the straightest road.

Panel buttons: **on/off**, **voice**, **surface** (tarmac / gravel / snow sets how much grip the braking cues assume), **1-6 / words** (the corner-call style), **end** (finish the drive) and **⚙** (all settings, see below).

**Braking aid:** while a brake cue shows, the status line fills up as you near the brake point (full = brake now). Settings → Driving aids → **bar + line across the road** also paints a brake line across the whole road (both lanes, flat on the surface, like the brake markers in Gran Turismo) where you need to be braking for the next corner: amber while it is coming, red once you should be braking. It is placed from your speed, so it is earlier when you are faster, but it stays put on the road: it only moves when the brake point moves more than 2.5 m, and then glides there, and it locks once you are on the brakes. **off** hides the visual cue (the spoken "brake" has its own switch).

**Settings (⚙ on the strip, or settings in the analysis panel):** every option in one place, grouped as co-driver (call timing, grades, surface, distance calls, crests, the navi-screen map), voice (voicepack, output, volume, chatter), driving aids (braking aid, spoken brake cues, slide hints, the learned grip with a reset button), lap timing (route discovery, this map's routes with **clear its laps** / **delete route**), analysis and recording, and the race engineer. Anything that deletes asks for a second click.

## Map on the car's center screen

Any car whose current configuration has a navigation screen also shows the coach's map there: the road ahead coloured by corner severity, the next call, its distance and the max speed. That includes the Vivace and ETK 800 road trims, plus the Scintilla, Bastion, ETK-C, van and others. Track and rally builds usually have no screen; for those the on-screen map panel is the map.

- **No game files replaced:** the coach draws a layer on top of the car's own navigator page. Switch the coach off, or the option below, and the stock navigator comes back.
- **The screen stays in view:** the first time you sit in such a car, the coach tilts the driver camera just enough to fit the screen at your FOV and saves that as the car's seat setting. A seat position you set yourself always wins.
- **Measured cars:** the ETK 800 needs a −4° tilt at FOV 36°. The Vivace needs −2.2° (Ardente and regular screens). Other cars use a typical screen position until measured.

```lua
coDriverCoach.setOption('consoleMap', false)  -- leave the car's screen alone
coDriverCoach.setOption('frameScreen', false) -- don't tilt the driver camera for it
```

## Co-driver voice

The coach plays one of the game's rally co-driver voicepacks (pick it in settings → voice). For the full set of calls and remarks below, record your own voicepack: read the 120 lines of [VOICE_SCRIPT.md](VOICE_SCRIPT.md) and build it with `tools/voicepack/` (see its README). It installs as the voicepack **custom**. The game's own packs don't have every word, so a few remarks are skipped with them. Besides corner calls it says:

- **Distances:** "two hundred, three left" when a corner is called from far away on a fast straight.
- **Road notes:**
  - small crest, crest, big crest, jump and dip, by size.
  - "over crest" when a crest is inside a corner.
  - "very long" for big sweepers.
  - "caution" or "double caution" when a corner needs a big speed drop.
- **Braking:** "brake", then "brake now" if you're late, or "brake hard" if you're very late.
- **Slides:** "oversteer"; "understeer, ease off"; "catch it" on a big slide, then "nice save" if you recover without hitting anything.
- **Gears:** "shift up" and "shift down" (manual gearbox in realistic mode).
- **Stages:** "stage ready, three, two, one, go", then "halfway", "one kilometer to go", "five hundred to go" and "finish".
- **Debrief:** "Drive complete. Nice drive. Overall grade B plus. Focus on smoothness."

Console switches:

```lua
coDriverCoach.setVoicepack('custom')            -- your own recorded pack (or 'ak_2026-04-16' for the game's default)
coDriverCoach.setOption('chatter', false)       -- corner calls and brake cues only
coDriverCoach.setOption('distanceCalls', false) -- no distance calls
coDriverCoach.setOption('voiceOutput', 'intercom') -- back to the game's rally intercom channel (default 'plain')
coDriverCoach.setOption('voiceVolume', 0.8)     -- voice loudness on the plain output (0-1, follows the UI volume too)
```

Corner calls always come first: chatter (remarks, progress, shift calls) only plays when nothing else is waiting, and a call that couldn't start within 2.5 s is skipped rather than played late.

To re-record, read the script with about a one-second pause after each line and send the recording; it gets split, checked and levelled the same way.

## Practice scenarios

Press **scenarios** on the coach strip (or bind "Co-Driver Coach: scenarios menu") to open a menu of one-click starts. Each one loads the map, puts you at a good start point, spawns a fitting car and sets the surface:

| Scenario | Map | Car | Surface |
|---|---|---|---|
| Mountain roads | Italy | Vivace track | tarmac |
| Castle town to coast | Italy | Covet rally (asphalt) | tarmac |
| Quarry climb | Italy | Sunburst rally (gravel) | gravel |
| Canyon highway | Utah | ETK 856 sport | tarmac |
| Desert dirt roads | Utah | D15 off-road | gravel |
| Redwood forest | West Coast USA | ETK 844 track (manual) | tarmac |
| Dirt track | West Coast USA | Sunburst rally (gravel) | gravel |
| Country back roads | East Coast USA | Covet sport | tarmac |
| Jungle rally | Jungle Rock Island | Vivace rally | gravel |
| Desert trails | Johnson Valley | Roamer off-road | gravel |
| Rally stage | Automation Test Track | BX rally (gravel) | gravel |
| Race circuit | Hirochi Raceway | Vivace race | tarmac |

- **Car:** "scenario car", or "my current car" to keep whatever you're driving.
- **Stage:** free drive, or a 2 / 4 / 6 km stage. The GPS sets a finish that far away by road and the coach follows the route. The strip shows the distance left, and crossing the finish ends the drive and opens the debrief with your stage time.
- **Same map, no reload:** if you're already on that map, it swaps the car and moves you to the start instead of reloading.
- **Restart last** (in the menu, or the "restart scenario" hotkey) loads the last scenario again with the same options.

## End-of-drive debrief

A drive starts when you move off. It ends when you press **end** (or the "end drive" hotkey), stay parked for 20 seconds, switch vehicle or leave the map. Drives under a minute or half a kilometre aren't graded.

The **Co-Driver Debrief** panel then shows your time, distance and speeds, plus a letter grade (A+ to F) for:

| Aspect | What it measures |
|---|---|
| Braking | Reacting to brake cues on time, and not braking too late |
| Corner entry | Corners where you carried too much speed *and* slid or ran wide |
| Commitment | How close clean corners got to the target speed (being too cautious costs time) |
| Car control | Oversteer, big slides and understeer per corner |
| Smoothness | How sharply the g-forces change, plus harsh stabs at the pedals or wheel |
| Staying on road | Time off the road, crashes and resets |
| Gear use | Time on the limiter or lugging (manual gearbox only) |

The overall grade is a weighted average.

- **Click any row** to see how that aspect is measured, your numbers, and exactly what gets you the next letter (for example "To reach B: brake earlier for 1 more corner").
- **"To get … overall"** lists the three changes that would raise your overall grade the most. Click one to jump to its details.
- **The Focus card** picks your lowest grade and explains what happened, gives two things to try on the next drive, and a mindset to carry into it.
- **Comparison:** each debrief compares against your previous drive. History is kept in `settings/coDriverCoach_history.json` (last 30 drives).

**Calibration**
- **Targets fit your car.** Target speeds and brake cues start from the surface setting, then rise to match the cornering and braking grip you've actually shown in that car. This is saved per car config and surface in `settings/coDriverCoach_cars.json`; delete it to start over.
- **Braking is judged on the outcome.** Braking later than the cue only counts against you if that corner then went wrong.
- **Smoothness ignores crashes and resets.** If you drive with keyboard pedals (only fully on or off), only steering smoothness is graded.

`coDriverCoach.testSummary()` shows a sample debrief from made-up numbers (not saved).

Optional hotkeys: Options → Controls → Bindings → Gameplay → "Co-Driver Coach: …".

## Drive analysis (race-engineer review)

While the coach is on, every drive is recorded in the background: about 60 Hz telemetry (position, speed, throttle, brake pedal, brake pressure, steering, gear, rpm, ABS, tyre load and the surface under the tyres) plus a game replay. The **● analysis** button on the coach strip shows a recording is running.

**End of session:** the debrief shows two buttons.
- **Keep recording:** close the debrief and carry on. The same session keeps recording.
- **Review analysis:** stop recording and open the analysis.

You can open the last analysis any time with **analysis** on the coach strip.

**What the analysis shows**
- **Better line:** a minimum-curvature line (outside, apex, outside) inside the road edges and clear of walls, barriers, banks and trees. These are found by raycasting sideways from where you drove, and every step of the line is checked across the car's width, so the line never goes through a wall.
- **Ideal speed:** an ideal speed profile from a model of your car on that road:
  - **grip** you showed consistently: the sustained peak of each corner, taken across corners rather than from one lucky moment, with crashes left out; per surface (tarmac, wet, gravel, grass, snow)
  - **aero downforce**, measured from tyre load against speed
  - **braking**, checked against what the car's brakes can deliver
  - **acceleration** from your full-throttle pulls, with the engine's power curve filling in the speeds you never pulled through
- **Model setting:** the model aims at a share of that limit so the better line is achievable rather than heroic: 95% by default, or 90% / 100% via the **model** button. Style is auto (circuit on Hirochi Raceway, the Automation test track, or walled tarmac; rally elsewhere), rally or circuit. Rally keeps more margin from road edges and walls and is more lenient on brake points, apex distance and coasting.
- **Time to find:** your time against the better line, and how much of the gap sits in the top 3 corners.
- **Map first:** the review is built around the map: the road, the better line (green dashes) and your line, which turns red where you lose time. Corner badges are green (on pace), amber (small loss) or red (most to gain). Click the map to move the cursor.
- **Corners ranked by time lost.** Each has an engineer's note, for example "Braked 18 m earlier than needed. Squeezed the brake on over 0.6 s: hit it firmly first, then ease off. Throttle 0.7 s later than possible". Click a corner to zoom the map and charts to it, with ideal and actual brake points, apex and throttle point.
- **Going well:** the strengths that showed up most (on pace, brake points on the mark, full apex speed, strong exits, trail braking...), with their corners. Each corner also lists what went well (✓) before what to try.
- **Next drive, try:** the two habits that cost the most time, worded as things to try.
- **Corner list:** in turn order, or **by time lost**. Replay prev/next follows the same order.
- **Telemetry charts** (the **telemetry** button; always shown during a replay): Δ time, speed (you vs better line), brake and throttle (yours vs ideal, plus brake pressure), steering and gear. Your inputs are drawn at full rate (a sample every 0.5 m), so zooming into a corner shows every input. **Drag** to scrub, **wheel** to zoom, **right-drag** to pan, **double-click** to reset. The readout shows the values at the cursor.
- **Replay, turn by turn:** **▶ replay** (from the selected turn), **▶** on a corner, or **replay from cursor** plays the drive continuously from there:
  - The better line (green) runs ahead of the car and your line (orange) trails behind it.
  - Each turn's BRAKE HERE / you braked / APEX / THROTTLE markers fade in as you approach and fade out after the exit.
  - **◀ turn / turn ▶** jump to the previous or next turn within the same playback (◀ restarts the current turn if you're more than 2 s into it).
  - The current turn is highlighted on the timeline and in the corner list.
  - Playback carries on across the 5-minute replay files. A gap in the recording is skipped with a note, and it pauses at the end.
  - A replay file the game can't read (now and then one is cut short when the recorder switches files) is tried once, skipped with a note ("Replay for 5:00–10:00 is damaged"), and its corners lose their replay buttons.
  - **back to analysis** puts your car back exactly where it was, facing the same way.
  - Controls: ¼× / ½× / 1× speed, and dragging the timeline seeks.
  - **back to analysis** returns your car and camera to where they were.

**Incidents:** corners where you crashed (an impact over 2.5 g), spun, went off the road or lost the car (speed down to 40% of what was possible), and the slow corners right after one, say so ("Crashed here"). They are left out of the tips and the positives. The headline shows the gap both with and without them, e.g. "47.2 s to find (13.9 s without 8 incidents)".

**What the notes check:** braking too early or too late (tolerance grows with the length of the braking zone), a slow initial brake squeeze (more lenient without ABS), low peak brake (judged against the pedal your brakes need to reach the limit), releasing and re-applying, no trail braking, coasting between brake and throttle, late throttle, steering corrections, distance from the better apex, minimum and exit speed, and braking where none is needed.

**Replay recording** (analysis panel → settings → Replay recording):
- **After a game update** BeamNG may switch mods off (the Mods button on the main menu shows a warning): turn them back on there, or the coach, its hotkeys and your wheel binding for the engineer are missing.
- **Game updates:** BeamNG 0.40 can't play replays recorded with 0.39 or older. Those turns lose their ▶ button and say "recorded with an older BeamNG version"; the telemetry, laps and analysis of those drives work as before. Settings → analysis and recording can delete those files.
- **Disk space:** settings → analysis and recording shows the replay files and their size, with **delete replays older than a week / a month** (a second click confirms; telemetry and laps stay). Nothing is ever deleted automatically.
- **laps / stages only** (default): the game replay records only during timed laps (see **Lap timing** below, from just before the start line), scenario GPS stages, or after you press the **"record replay for this drive"** hotkey (bind it under Gameplay). It also records while you drive along a saved route (an out-lap joining it part way round) and the lap that confirms a newly found loop; only the very first lap of a new loop has telemetry without a replay.
- **always**: every drive. It costs about 1.3–1.9 ms per frame while driving (measured).
- **off**: telemetry only, best frame rate, no corner replays.

Telemetry (and the whole analysis) records in every mode.

**Storage**
- Replays use about 55 MB per minute while recording. The mod **never deletes recordings or sessions automatically**; the panel shows how many replay files are kept. Delete old files in `replays/codriver/` yourself when you want the space back.
- Recording pauses after 90 s parked, and missions or your own replays take priority.
- The last session's telemetry is saved to `settings/coDriverCoach/last_session.json`. `coDriverAnalysis.loadLast()` re-opens it after a game restart.
- **Past sessions:** every session of a minute or 500 m and more is also kept in `settings/coDriverCoach/sessions/` (the last 20, about 6 MB per 15 minutes). This happens whether it ends with Review or not (car switch, level change, coach off). Open one with **sessions** in the analysis panel, or `coDriverAnalysis.loadSession(name)` / `listSessions()` from the console. Replays are only kept for the latest sessions, so older ones open without replay buttons.

Method notes: [docs/ANALYSIS_DESIGN.md](docs/ANALYSIS_DESIGN.md).

### Reviewing laps
When the drive has timed laps, the analysis shows a **LAPS** strip under the header and a **lap times** table: each lap's time, its gap to your best, three sectors (your best sector in purple) and the turns where it lost most against your best pass of each turn. The header line gives the theoretical best (your best 10 m stretches of every valid lap joined up; the table also gives the 50 m one).
- A drive with laps **opens on your best lap**; the lap table stays at the top of the side panel (click the highlighted row or **all** for the whole drive).
- **Click a lap** (strip or table) to study it: the map, charts and corner list show only that lap, corners are numbered as the route's turns (**T1, T2...**, the same place on every lap), each turn says how far it was from your best pass there, and the Δ chart becomes **time to your best lap** (purple; above zero you are behind). **▶ replay lap N** plays it from the start line. **all** goes back to the whole drive.
- **Compare two laps:** studying a lap, pick another in **COMPARE WITH** (your best by default). The map shows both lines (the other one in blue), the Δ chart becomes the gap between them at the same place on the road, the speed chart shows both, and each turn lists both times.
- **Where the time is:** studying a lap, a short list under the lap table shows the stretches of road where it lost time to the compared lap (your best by default), sharpest first: "T2 exit to T4 exit · 537 m · −2.42 s · 0.45 s/100 m". The laps are timed over 10 m pieces of road; the quicker lap owns each piece, tiny back-and-forth swaps are smoothed out, and stretches under 0.02 s are left out. A short stretch where you lose a lot per metre ranks above a long one where you lose a little. Up to three places where the lap was quicker follow with a ✓. On your best lap, the list shows where your other laps were quicker (and which lap). **Click a stretch** to zoom the map and charts to it.
- **Your best ever:** the best lap on each route is kept (from whichever drive set it), so **COMPARE WITH** also offers **best ever 1:00.309** when your best ever comes from another drive. The map shows its line in blue, the charts the gap and both speeds, and **where the time is** lists where this lap lost and won time against it. On the lap that *is* your best ever, the row says so. Older bests are picked up from your saved drives the first time you load the map.
- **Balance** (map button): colours your line by the car's balance: **red** where it pushed wide (understeer: much less turn than your steering asked for, near the grip limit), **teal** where the rear stepped out (oversteer: the car pointing further into the turn than it travelled, or countersteer with a slide), grey where it was neutral. Each corner also says it in words ("Balance: pushed wide on entry", "rear stepped out on exit"), and the engineer knows it. Understeer needs your steering input in the recording, so AI drives only show oversteer.
- **Measured power:** the car line under the map adds the power measured at the wheels on your full-throttle pulls ("270 kW (about 207 kW measured at the wheels, 99 km/h)"). It is lower than the listed engine power by the drivetrain loss and the drag at that speed (on the Vivace about 77 to 83%); a much lower figure than usual points at a problem (damage, a wrong tune).
- **Quicker lap** (map button, when comparing): colours your line by which of the two laps was quicker on each 10 m (orange: the lap you study, blue: the other one).
- The engineer knows the laps: ask "how consistent was I?", "what did lap 4 do wrong?" or "where did lap 4 lose time?" (it gets each lap's sharpest stretches), and **debrief** on a selected lap compares it with your best lap.

## Lap timing (automatic, free roam)
The coach recognises laps by itself:
- **Loops:** drive a circuit twice. When you come back onto your own path in the same direction (at least 600 m later) and drive it all the way round again, the loop is saved with a start line where you rejoined it. Laps 1 and 2 are timed after the fact, and from lap 3 the strip shows the running lap: **Lap 3 · 1:12.4 · −0.38 · best 1:23.912**. At each third of the lap it shows that sector's own gap to your best for a few seconds (**S2 +0.31**), and for 5 seconds after the line the lap's result. Settings → race engineer → **spoken lap times** has the engineer say the time and the gap at the line ("Lap 3, one oh oh point five, two tenths off your best").
- **Point to point:** drive a road, then reset or teleport back to where you started and drive it again. After 300 m it becomes a route from that start to where the first run ended, and the run is timed.
- **Mark it yourself:** bind **lap timing start here** and **lap timing finish here** (Gameplay). Mark a start, then a finish for a point-to-point route, or drive back over the start mark for a loop.
- **Saved routes** time themselves every time you cross their start line in the right direction, on any later drive.
- **Official courses:** the map's own quick race layouts (West Coast USA has 13, Italy 13, Utah 6; reversible ones twice, forward and reverse) are listed with their real names and lengths. They are **off by default**, so they don't all time at once: in settings → lap timing, **show all courses** lists them with their length, laps and best, and **time this course** turns one on (the ones that are on stay listed). A lap on a course also has to pass every one of its checkpoints. A loop the coach found by itself that is the same as a course you turned on leaves its laps to the course. Courses can't be deleted, only turned off.
- **Recce pacenotes** (settings → lap timing, per route): press **recce next lap**, then drive one lap of the route (slowly is fine, like a real recce). The co-driver's calls on that lap are kept with their places on the route, and from then on every lap there gets exactly those calls at the same places, so the notes no longer change with your speed or line. Your call timing setting still decides how early they come. A recce of part of a route (the lap was dropped) covers the part you drove, and the normal calls take over after it. The row then shows **recce: 17 calls · clear**; `coDriverCoach.setOption('recce', false)` ignores recces without deleting them.
- **Ghost of your best lap** (settings → lap timing, off by default): while a lap is timed, a blue marker floats where your best lap on that route was at the same lap time; **marker + its line** also draws your best lap's line for the next 200 m. It costs about 0.04 ms a frame.
- **Getting to a start line:** every route and course row in settings → lap timing shows how far away its start is, with **guide me** (the game's blue ground arrows lead you there; they go away when you arrive or that lap starts) and **take me there** (your car is put about 40 m before the line, facing it). The courses list puts the timed ones first, then the nearest.
- **Starting a lap** needs the car to cross the start line while following the route there, so driving across a start line from a side street starts nothing.
- **Valid lap:** at least 90% of the checkpoints (every 100 m) passed in order, a distance within 15% of the route, no reset, and no more than 3 s or 150 m off the route. Otherwise the lap is marked invalid with the reason (left the route, car reset, missed checkpoints). Far off the route (30 s or 600 m) the lap is dropped, and kept as a partial lap if it covered a quarter of the route.
- Laps are saved with the drive's session (the sessions list shows the lap count and best lap) and per level in `settings/coDriverCoach/routes/<level>.json`, with each route's best lap and its last 30 laps. The best lap's own line (4 m points with time, speed, throttle and brake, about 20 KB) is in `routes/<level>_best/<route>.json`, for the best-ever compare and the ghost.
- A found loop's first lap is only timed if the car kept moving (an average of at least 18 km/h): a lap with a long stop in it isn't a lap. A route saved from a lap that had a reset in it (the car put back a little way) has the repeated stretch cut out when it loads.
- **Console:** `coDriverLaps.getRoutes()` (your own routes), `coDriverLaps.getCourses()` and `coDriverLaps.setCourseEnabled(id, true|false)` (official courses), `coDriverLaps.clearRoute()` (deletes the route being timed, or the nearest one, with its best-lap line and recce), `coDriverLaps.clearLaps(id)` (forgets a route's laps and best, and its best-lap line), `coDriverLaps.setOption('discovery', 'off')` to stop finding routes by itself (saved and marked routes still time), `coDriverLaps.setOption('ghost', 'off' | 'marker' | 'line')`.

## Privacy and security

- Only the race engineer sends anything off your computer, and only with an Anthropic API key set: your question as text, and the car and drive data it needs. The bridge sends no audio; speech recognition and the voice run locally.
- The engineer's voice log keeps your push-to-talk clips on disk, the newest 300 (`"voice_log_keep": 0` in `tools\engineer_config.json` keeps text only).
- Keep `tools\.anthropic_key` readable by your account only, and turn off the game's own MCP server (`enableMcp`) when you're not developing: it lets local programs run Lua in the game.
- Details, and the state of the last security review: [SECURITY.md](SECURITY.md).

## Race engineer (voice questions, Claude Haiku)

You get a race engineer you can talk to. Mid-drive it reports on the car, conditions and your laps ("how was the last lap?", "what's my best?"); in the analysis panel it debriefs you, lap by lap when the drive has laps. It answers what you asked: car details only come up when you ask about them or something needs attention.

**Start it:** double-click `tools\engineer.bat` and leave the window open while you play.

**Best speech (recommended, one time):** run `tools\engineer_setup.bat`. It sets up a local Python environment (`tools\.venv`, about 450 MB with models) with:
- **Whisper** (faster-whisper `base.en`) to understand you. On your recorded voice lines it got about 93% right, against about 5% for Windows dictation. It takes about 1 s per question on 2 CPU threads, and costs about 3 fps for that second.
- **How it hears you:** the mic keeps the half second before you press the button (in memory only), so your first word isn't cut off; the audio is cleaned (engine rumble removed, a quiet mic brought up) before Whisper hears it; in the analysis it listens for debrief words (corners, turns, laps); when it's unsure it takes a second, wider pass; and noise or a mumble counts as "didn't catch that" instead of a made-up question. On a test with three voices and engine rumble it went from 16 to 30 of 36 phrases exactly right.
- **Kokoro**, a natural-sounding local voice for the engineer (default `af_heart`). It speaks sentence by sentence, so it starts after about 0.9 s. **Piper** is the lighter fallback.

Without it, the engineer falls back to Windows dictation and the Zira voice.

**Voice settings:** edit `tools\engineer_config.json` (your personal copy, ignored by git; `engineer_config.example.json` is the shared default), then restart `engineer.bat`:
- `kokoro_voice`: `af_heart` (default), `af_bella`, `af_nicole` (soft whisper), `bf_emma`, `bf_isabella`, `bf_alice` (British) and more
- `speed`: Kokoro speaking speed (`0.95`); `tts_threads`: CPU threads for the voice (`4`; it only speaks in the analysis, while you're parked)
- `tts`: `kokoro` (default) or `piper`; `voice` is the Piper fallback voice (`en_GB-jenny_dioco-medium`)
- `persona_prompt` (optional, Haiku only): your own personality for the engineer (for example "You are a dry, sarcastic British engineer."). Without it the engineer is a straight, professional race engineer. The facts and numbers stay exact either way.
- `volume`: `1.0` is normal
- `drive_prompt` / `review_prompt` (optional): your own instructions for the engineer, replacing the built-in ones. These replace its job description, not its personality (use `persona_prompt` for that), and a review prompt that doesn't ask for a debrief of the run breaks the analysis answers. The radio rules are always added on top: mid-drive answers are one short sentence about what you asked (about 12 words), only an actual problem gets mentioned unprompted, and it doesn't repeat itself within a few minutes. Analysis answers match the length of the question.
- `whisper` and `threads`: the speech model (`base.en`) and CPU threads (`2`); more threads is faster but costs frames while it works

**Check what it heard (voice log):** every push-to-talk is logged with its audio clip, what Whisper heard, how sure it was, and the engineer's answer (in `settings/coDriverCoach/engineer/voicelog/` in your BeamNG user folder; the newest 300 clips are kept, about 30 MB). Double-click **`tools\voice_review.bat`** to open the review page in your browser:
- play each clip, see what was heard and how sure it was, and either mark it **✓ right** or type what you actually said;
- rate each answer **clear**, **too long**, **unclear** or **wrong**;
- the top shows the word error rate of what you've reviewed, how often it didn't hear you, and how long hearing and answering took.

Your corrections teach it: a mishearing you correct twice becomes an automatic fix (for example "last slip" → "last lap"; you can switch each one off on the page), and words it keeps missing are added to Whisper's vocabulary. The bridge picks these up on the next question, no restart needed. The page only opens on this computer.

Related settings in `tools\engineer_config.json`: `mic_preroll` (`true`; `false` opens the mic only while you hold the button) and `voice_log_keep` (`300` clips; `0` keeps no audio, only the text).

Answer settings: `local_answers` (`true`; `false` sends every question to Haiku), `drive_thinking` (`true`: mid-drive answers think for a moment, about 2.1 s instead of 1.5 s, and come out clean; `false` for speed) and `review_tools` (`false`; `true` makes the analysis look details up instead of reading the whole analysis, which measured slower and dearer because the whole analysis is cached after the first question). `python -I tools\engineer_eval.py` asks 30 test questions and prints the answers, the share answered locally, timings and tokens (it uses your API key, a few cents).

**Add Haiku:** put your Anthropic API key in `tools\.anthropic_key` (one line; git-ignored) or set `ANTHROPIC_API_KEY`, then restart the bridge. Each question costs a fraction of a cent.

**Talk to it**
- **Mid-drive:** bind **Co-Driver Coach: talk to engineer (hold)** to a wheel button (Options → Controls → Bindings → Gameplay). Hold it, ask, release. The question and answer appear on screen (spoken only in the analysis; turn mid-drive voice on with `coDriverEngineer.setOption('speakDrive', true)`). Try:
  - "how are my brakes?", "tyre temperatures", "is the engine overheating?"
  - "how much fuel?", "any damage?", "status report", "what's the weather?"
  - "more front bias", "make the wheel lighter", "sport mode", "traction control off", "undo that" (see **Car adjustments** below)
  - "how was that corner?", "what happened back there?": it knows your last corners (your speed against the co-driver's call), crashes, resets, laps and its own alerts
- **Quick answers without the internet:** simple status questions ("brakes?", "fuel?", "any damage?", "how is the car?", "how was the last lap?", "what's my best?", "how am I doing?", "speed?", "what have you changed?") and radio checks are answered straight from the car's data, instantly and for free. Speech it isn't sure it heard right gets "Say again?" instead of a guess. On a 20-question test, 13 were answered this way.
- **Your voice for short lines** (settings → race engineer, on by default): an engineer line whose every word is in your own co-driver voicepack (see Co-driver voice) ("Nice save", "Brake hard", "New best", "Slow down", "Are you okay?") is said with your recorded clips instead of Kokoro. Longer answers, numbers and lap times stay with Kokoro.
- **Checked answers:** a Haiku answer that explains itself ("The driver asks...") instead of being the radio line is trimmed or asked again, and one with a number that isn't in the car's data is asked again once.
- **Status report button:** **Co-Driver Coach: car status report** reads out brakes, tyres, engine, fuel and damage without asking.
- **In the analysis panel:**
  - **🎙 hold to ask** (or type in the box and press Enter), e.g. "why was corner 3 slow?", "what should I work on?", "am I braking too early?".
  - **engineer debrief** gives the whole run in a few sentences. With Haiku it remembers the conversation, so you can ask follow-ups.

**Car condition calls (automatic, mid-drive):** the engineer speaks up when something needs attention:
- brake fade (only once the brakes are hot; cold brakes are normal) or failed brakes
- punctures and broken wheels, overheating tyres
- engine water or oil overheating, and engine damage (leaks, head gasket, down on power, over-rev, turbo heat)
- low and critical fuel

Each call is made once and re-armed when the problem clears or you reset the car. They show on screen; turn them off with `coDriverEngineer.setOption('alerts', false)`. Analysis answers are spoken; mute them with `setOption('speak', false)`.

The co-driver strip at the top hides while the analysis is open.

**Car adjustments (mid-drive, by voice):** ask the engineer to change the car on the fly: brakes, force feedback and the car's own electronics. Nothing is written to the car's config, tuning or your input bindings.

| Ask for | Changes | Step | Limits |
|---|---|---|---|
| "more front bias", "move the bias back" | brake bias: braking moved between the axles, total braking unchanged | 2 points | ±10 points from the car's stock balance |
| "soften the brakes", "more brake power" | overall brake strength | 5% | 80% to 110% of stock |
| "make the wheel lighter", "FFB heavier" | steering-wheel force feedback | 10% | 60% to 130% of your binding's strength |
| "sport mode", "switch to comfort" | the car's drive mode | | the car's own modes |
| "traction control off", "ESC on", "ABS off" | driver aids | | on or off |
| "launch control on", "launch rpm 4500" | two-step launch control | 500 rpm | 1500 rpm to 90% of the rev limit |
| "more centre lock" | AWD centre coupling, minimum lock | 10% | 0 to 60% |
| "undo that", "put it back", "back to stock" | everything back to stock | | |

- Only the cars that have them get the electronics (on a Vivace Ardente: four drive modes, ESC, traction control, ABS, launch control and centre lock). Ask for something the car doesn't have and the engineer says so.
- It only changes something when you ask for a change. "Brakes feel weak" or "what's my bias?" gets an answer, maybe an offer ("Want it lighter?"); say "yes" and it does it. Name a number ("force feedback to 80 percent") and it goes straight there, within the limits. ESC, traction control and ABS only go off when you name them.
- The change waits until the wheel is near straight and you're off the brake, then applies. Force feedback ramps over about a second, so the wheel never jolts. A short line on screen confirms it ("Engineer: set, brake bias 79% front (+2), Sport mode, traction control off.").
- **Same car, same settings:** they stay through resets and recoveries, and come back if you reload the same car (model, config and tuning). They clear when the drive session ends (Review, coach off, level change) or you change car. Picking a drive mode yourself replaces the engineer's electronics changes; changing force feedback in Options wins too.
- The engineer knows what's set and what the car is running, so "what have you changed?" works. Without Haiku the simple phrases above still work.
- Console: `coDriverEngineer.revertAdjustments()` puts everything back.

**Weather:** the engineer knows the time of day, temperature, cloud, fog, wind and whether it's raining. In BeamNG the weather is set per level or preset rather than changing on its own, and rain is visual only (no wet grip), so set the coach's surface if you want different targets.

## Development and tests

- **Deploy while the game runs:** `bash tools/deploy.sh` (Git Bash) copies the mod into your user folder and reloads it in the game. It needs the game's local MCP server: Options, or start the game with `-enablemcp`. Turn it off again afterwards (see [SECURITY.md](SECURITY.md)). `BEAMNG_USER` points it at another user folder.
- **Offline tests** for the analysis, lap timing and recce run in node, with no game: setup and the list are in [tools/offline/README.md](tools/offline/README.md).
- **The engineer bridge's tests:** `python -I tools/test_engineer_local.py` and `python -I tools/test_engineer_adjust.py`. They need no game and make no network calls.
- **Developer notes:** [DEV_CONTEXT.md](DEV_CONTEXT.md) explains how everything works and what was measured; [ROADMAP.md](ROADMAP.md) covers what's next.

## Tuning (console, `~` key, GE Lua)

Everything here is also in the settings panel (⚙, or bind **Co-Driver Coach: settings** under Gameplay); the console still works.

```lua
coDriverCoach.setCallAhead(5.5)                       -- call corners earlier (seconds)
coDriverCoach.cycleVoicepack()                        -- switch co-driver voice
coDriverCoach.setOption('crests', false)              -- stop calling crests
coDriverCoach.setOption('carControl', false)          -- stop slide hints
coDriverCoach.setOption('toasts', true)               -- also show calls in the Messages app
coDriverCoach.setOption('brakeAid', 'zone')           -- braking aid: 'off', 'bar' (default) or 'zone'
dump(coDriverCoach.getDebugState())                   -- see what the coach sees
```

Settings are saved to `settings/coDriverCoach.json` in your BeamNG user folder.

## Corner scale (1-6 mode)

6 is the fastest corner and 1 the slowest. Below 1 come square (90° junction turns) and hairpins.
The grade comes from the corner's radius, adjusted for how much you can straighten the line through it.
