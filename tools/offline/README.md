# Offline analysis tests

Runs `coDriverAnalysis.lua` outside the game, in fengari (Lua 5.3 in node), with mocked game APIs
(`mocks.lua`: road graph, `castRayStatic` against 2D wall segments with a ground plane at z = 0, FS,
JSON). LuaJIT in the game is about 50 times faster, so time the analysis in game.

**Setup once.** You need Node.js 18 or later. Install fengari in a folder outside the repo (nothing
from npm is committed), and point `NODE_PATH` at it:

```
mkdir %TEMP%\cdcfengari && cd %TEMP%\cdcfengari && npm install fengari@0.1.4
set NODE_PATH=%TEMP%\cdcfengari\node_modules
```

**Running a test.** Each test runs as `node tools/offline/run.js <extension.lua> tools/offline/<test>.lua`, from an
**empty folder** that contains `settings/coDriverCoach/` (the tests write their files there). From Git Bash:

```
d=$(mktemp -d) && mkdir -p "$d/settings/coDriverCoach" && cd "$d"
NODE_PATH=$TEMP/cdcfengari/node_modules node <repo>/tools/offline/run.js <repo>/co_driver_coach/lua/ge/extensions/coDriverLaps.lua <repo>/tools/offline/t_laps.lua
```

Settings go in as environment variables (`SRC=`, `MODE=`, `OUT=` and so on, listed per test below). Each test ends
with `ALL PASSED`, `PASS` or the number that failed.

**Two kinds of test.**
- **Standalone** (`t_laps`, `t_courses`, `t_recce`, `t_walls`, `t_slope`, `t_adjust`): need nothing but the repo.
- **On your own recordings** (`t_lapscope`, `t_bests`, `t_balance`, `t_replay`, `t_session`, `t_make_v1` / `t_archive`): need
  `SRC=` pointing at one of your saved drives, in `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\settings\coDriverCoach\sessions\`.
  `t_lapscope` and `t_bests` need a drive with three or more laps of one route; `t_balance` a drive with your own steering (an
  AI drive records none). They only read that file.

**The engineer bridge's tests** are plain Python, need no game and make no network calls:

```
python -I tools/test_engineer_local.py
python -I tools/test_engineer_adjust.py
```

`python -I tools/engineer_eval.py` is different: it asks Claude Haiku 30 test questions with your API key (a few cents).

- `t_session.lua`: analyses `settings/coDriverCoach/last_session.json` relative to the working
  directory (run it from the game's user folder `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current`).
  There is no road graph or wall data offline, so every point counts as off-graph. `OUT=<file>`
  writes the result JSON (handy for loading the panel in a browser with AngularJS).
- `t_make_v1.lua` (run with main's `coDriverAnalysis.lua` as the extension, `SRC=<session file>`) writes a 20 Hz v1
  session that main has analysed and saved; then `t_archive.lua` (the branch's extension) checks that it loads,
  gets archived, opens with `loadSession`, and that the archive keeps 20 and skips short sessions.
- `t_replay.lua` (`SRC=<session file>`): the continuous replay with a mocked core_replay: three replay files (the last
  after a 3 s gap), the turns in order, the end of the recording, and turn-by-turn steps. `MODE=damaged` makes the middle file fail to load,
  `MODE=refused` makes it load without playing (how 0.40 refuses a file), `MODE=oldversion` makes it a file from an older
  game version (skipped without loading).
- `t_laps.lua` (run with `coDriverLaps.lua` as the extension, from an empty folder): lap and route recognition on
  synthetic tracks driven at 60 fps, from loops and point-to-point runs to the cases that must not make a route
  (roundabout, out and back, an overpass).
- `t_courses.lua` (with `coDriverLaps.lua` as the extension, from an empty folder): official courses on a mocked
  quick race layout (a `.json` with base, forward and reverse prefabs, and a `.race.json`) over a mocked road graph:
  the lines follow the graph, a course that is off times nothing, one turned on times laps with every checkpoint,
  the reverse is a separate course, a loop found while a course was off defers to it once it is on, and a street
  crossing the finish line (or the circuit) starts no lap. `run.js` puts the extension's folder on `package.path`
  so `require('coDriverLaps/courses')` works.
- `t_lapscope.lua` (`SRC=<session file with laps>`): the lap analysis on a real session: each lap's sectors, gap, time to the best lap and the turns matched across laps; checks that the sectors add up to the lap time and that the time to the best lap at a lap's end matches its gap. Then the 10 m stretches ("where the time is"): the cell times add up to each lap's gap, the kept stretches come within 0.1 s of it, the lists are in rate order, the 10 m theoretical best is no slower than the 50 m one or the best lap, plus a synthetic flicker merge. `ENG=<repo>/co_driver_coach/lua/ge/extensions/coDriverEngineer.lua` also prints the engineer's lap context; `OUT=<file>` writes the result.
- `panel_stretches.js` (plain node, `node tools/offline/panel_stretches.js <app.js> <result.json from t_lapscope OUT=>`): loads the analysis panel with a stub angular and checks that its stretches for every lap against the best one match the Lua side's.
- `t_bests.lua` (`SRC=<session file with laps>`, `ROUTE=` default r1): best laps across drives: the best lap's file made from the archive, the same-drive flag, another lap saved as the best ever lines up with that lap within 0.15 s, its stretches and line.
- `t_balance.lua` (`SRC=<session file>`): the car's balance per point and measured power: share flagged understeer and oversteer, the steering gain, each corner's balance note, spins flagged, measured power against the listed figure, and a made-up slide (the heading turned into the turn through an apex) that must be flagged.
- `t_recce.lua` (with `co_driver_coach/lua/ge/extensions/coDriverCoach/recce.lua` as the extension, from an empty folder): recce pacenotes on a mocked 2 km loop: a recce lap is kept, later laps at different speeds call the corners in route order once per lap with none repeated across the start line, the coach is held back inside the recce, a partial recce covers only what was driven and hands back to the coach, clearing removes it.
- `t_walls.lua`: a synthetic 90-degree corner with a 6 m road graph. `MODE=walls` puts walls at 3 m
  inside and 4 m outside, `post` a post at the apex, `post2` a thin post between ray positions,
  `none` nothing. It prints how close the better line gets to a wall and its offset through the
  corner. Run it from an empty folder containing `settings/coDriverCoach/` (it writes a session there).

- `t_adjust.lua` (`SRC=<repo>/co_driver_coach/lua/ge/extensions/coDriverEngineer.lua`, with
  `coDriverRec.lua` as the extension): the race engineer's car adjustments, with the vehicle and game-engine sides
  talking through captured queue strings. It covers clamping, waiting for a straight, the brake torque split, the
  force feedback ramp, the car's electronics, keeping the set through a reset and a reload of the same car,
  and clearing it on undo, session end, car switch or change, binding changes and the driver's own drive mode. Run it from an empty folder. The bridge side
  is `python -I tools/test_engineer_adjust.py`.

```
NODE_PATH=$TEMP/cdcfengari/node_modules MODE=walls node tools/offline/run.js co_driver_coach/lua/ge/extensions/coDriverAnalysis.lua tools/offline/t_walls.lua
```
