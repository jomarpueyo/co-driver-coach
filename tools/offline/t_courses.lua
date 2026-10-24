-- Official courses (coDriverLaps.lua as A, with coDriverLaps/courses.lua): a mocked quick race layout
-- on a mocked road graph, driven through A.step at 60 fps. Run it from an empty folder: it writes
-- levels/t_course/quickrace/ and settings/coDriverCoach/routes/ there.
--   node tools/offline/run.js co_driver_coach/lua/ge/extensions/coDriverLaps.lua tools/offline/t_courses.lua
local pi, sin, cos, sqrt, abs = math.pi, math.sin, math.cos, math.sqrt, math.abs
local DT = 1 / 60
local fails = 0
local function check(ok, what)
  print((ok and 'ok   ' or 'FAIL ') .. what)
  if not ok then fails = fails + 1 end
end

local function prep(pts, closed)
  local s = { 0 }
  for i = 2, #pts do s[i] = s[i - 1] + sqrt((pts[i][1] - pts[i - 1][1]) ^ 2 + (pts[i][2] - pts[i - 1][2]) ^ 2) end
  local len = s[#pts]
  if closed then len = len + sqrt((pts[1][1] - pts[#pts][1]) ^ 2 + (pts[1][2] - pts[#pts][2]) ^ 2) end
  return { pts = pts, s = s, len = len, closed = closed }
end

local function at(p, d)
  if p.closed then d = d % p.len else d = math.max(0, math.min(d, p.s[#p.s])) end
  local lo, hi = 1, #p.s
  while hi - lo > 1 do
    local mid = math.floor((lo + hi) / 2)
    if p.s[mid] <= d then lo = mid else hi = mid end
  end
  local a = p.pts[lo]
  local b = p.pts[lo + 1] or (p.closed and p.pts[1] or a)
  local sb = p.s[lo + 1] or p.len
  local f = sb > p.s[lo] and (d - p.s[lo]) / (sb - p.s[lo]) or 0
  local dx, dy = b[1] - a[1], b[2] - a[2]
  local l = sqrt(dx * dx + dy * dy)
  if l == 0 then l = 1 end
  return a[1] + dx * f, a[2] + dy * f, 0, dx / l, dy / l
end

-- drive from distance d0 to d1 along a path at speed v; watch(d) is called every frame
local function drive(p, d0, d1, v, watch)
  local d = d0
  while d < d1 do
    local x, y, z, ux, uy = at(p, d)
    A.step(DT, x, y, z, ux * v, uy * v, 0, ux, uy)
    if watch then watch(d) end
    d = d + v * DT
  end
end

-- the distance along p of its point nearest (x, y)
local function dOf(p, x, y)
  local best, bd = 0, math.huge
  for i, q in ipairs(p.pts) do
    local d = (q[1] - x) ^ 2 + (q[2] - y) ^ 2
    if d < bd then best, bd = p.s[i], d end
  end
  return best
end

local function rect(w, h, r)
  local pts = {}
  local function arc(cx, cy, a0)
    for i = 0, 15 do local a = a0 + i / 15 * pi / 2 pts[#pts + 1] = { cx + r * cos(a), cy + r * sin(a), 0 } end
  end
  for x = 0, w, 2 do pts[#pts + 1] = { x, -r, 0 } end
  arc(w, 0, -pi / 2)
  for y = 0, h, 2 do pts[#pts + 1] = { w + r, y, 0 } end
  arc(w, h, 0)
  for x = w, 0, -2 do pts[#pts + 1] = { x, h + r, 0 } end
  arc(0, h, pi / 2)
  for y = h, 0, -2 do pts[#pts + 1] = { -r, y, 0 } end
  arc(0, 0, pi)
  return pts
end

local function courseBy(id)
  for _, c in ipairs(A.getCourses()) do if c.id == id then return c end end
end
local function routeBy(id)
  for _, r in ipairs(A._routes()) do if r.id == id then return r end end
end

-- what the analysis would get
local LAPS = {}
coDriverAnalysis = { onLap = function(info) LAPS[#LAPS + 1] = info end }
local function lapsOn(id, from)
  local out = {}
  for i = from or 1, #LAPS do if LAPS[i].route == id then out[#out + 1] = LAPS[i] end end
  return out
end
local function fmt(l) return string.format('%.3f%s cp %s/%s', l.time, l.valid and '' or (' invalid: ' .. tostring(l.reason)),
  tostring(l.checkpoints and l.checkpoints.passed), tostring(l.checkpoints and l.checkpoints.total)) end

-- the road graph: a 1450 m rounded rectangle (nodes every 10 m on the straights), and a straight
-- street crossing its bottom straight at 60 degrees through the finish line
local loop = prep(rect(400, 200, 40), true)
local V = 25
local nid, first = 0, nil
local function node(x, y, r)
  nid = nid + 1
  MOCK_NODES['n' .. nid] = { pos = vec3(x, y, 0), radius = r or 5 }
  return 'n' .. nid
end
local prevN, finishN, spurN
for i = 1, #loop.pts, 5 do
  local p = loop.pts[i]
  local n = node(p[1], p[2])
  if abs(p[1] - 200) < 0.1 and abs(p[2] + 40) < 0.1 then finishN = n end
  if abs(p[1] - 300) < 0.1 and abs(p[2] + 40) < 0.1 then spurN = n end
  if prevN then MOCK_EDGES[#MOCK_EDGES + 1] = { prevN, n } else first = n end
  prevN = n
end
MOCK_EDGES[#MOCK_EDGES + 1] = { prevN, first }
-- a 15 m dead-end spur off the bottom straight at 300 m, with a checkpoint at its end
MOCK_EDGES[#MOCK_EDGES + 1] = { spurN, node(300, -55) }
local cx, cy = cos(pi / 3), sin(pi / 3)
local prevC
for k = -15, 15 do
  local n = k == 0 and finishN or node(200 + 20 * k * cx, -40 + 20 * k * cy)
  if prevC then MOCK_EDGES[#MOCK_EDGES + 1] = { prevC, n } end
  prevC = n
end

-- the layout: finish line at 200 m, checkpoints at 300 m (13 m off the road, on the spur), 700, 950,
-- 1200 m; the reverse prefab moves one
local function wp(name, d, r, shift)
  local x, y = at(loop, d + (shift or 0))
  return string.format('   new BeamNGWaypoint(%s) {\n      drawDebug = "0";\n      position = "%.4f %.4f 0";\n      scale = "%d %d %d";\n      mode = "Ignore";\n   };\n', name, x, y, r, r, r)
end
local DIR = 'levels/t_course/quickrace/'
mkdirJS(DIR)
writeText(DIR .. 'test_loop.json', jsonEncode({ name = 'quickrace.t_course.test_loop.title', closed = true, reversible = true,
  lapCount = 2, lapConfig = { 'Checkpoint_1', 'Checkpoint_2', 'Checkpoint_3', 'Checkpoint_4' }, finishLineCheckpoint = 'Checkpoint_finish' }))
writeText(DIR .. 'test_loop.prefab', '//--- OBJECT WRITE BEGIN ---\n$ThisPrefab = new SimGroup() {\n   canSave = "1";\n'
  .. '   new TSStatic() {\n      shapeName = "/art/shapes/race/s_concrete_race_barrier.dae";\n      position = "1 2 3";\n   };\n'
  .. wp('Checkpoint_finish', 200, 8) .. wp('Checkpoint_1', 300, 8):gsub('position = "[^"]*"', 'position = "300 -53 0"') .. wp('Checkpoint_2', 700, 8)
  .. '   new SimGroup(signs) {\n' .. wp('Checkpoint_3', 950, 8) .. '   };\n' .. wp('Checkpoint_4', 1200, 8) .. '};\n')
writeText(DIR .. 'test_loop_forward.prefab', '$ThisPrefab = new SimGroup() {\n};\n')
writeText(DIR .. 'test_loop_reverse.prefab', '$ThisPrefab = new SimGroup() {\n' .. wp('Checkpoint_2', 700, 9, -10) .. '};\n')
-- a race.json layout (the newer format), point to point along the top straight
writeText(DIR .. 'top_sprint.race.json', jsonEncode({ name = 'quickrace.t_course.top_sprint.title', startNode = 1, endNode = 3,
  classification = { closed = false, reversible = false, branching = false }, defaultStartPosition = 9,
  startPositions = { { oldId = 9, pos = { 390, 240, 0 } } },
  pathnodes = { { oldId = 1, pos = { 300, 240, 0 }, radius = 7 }, { oldId = 2, pos = { 200, 240, 0 }, radius = 7 }, { oldId = 3, pos = { 50, 240, 0 }, radius = 7 } },
  segments = { { from = 1, to = 2 }, { from = 2, to = 3 } } }))
FS.findFiles = function(_, dir, pattern)
  if tostring(dir):find('t_course/quickrace') then
    return { '/' .. DIR .. 'test_loop.json', '/' .. DIR .. 'top_sprint.race.json' }
  end
  return {}
end

local function newLevel(name) MOCK_LEVEL = name A._reset(name) end
newLevel('t_course')

-- 1. the layouts load: forward and reverse, a line along the road graph, off by default -----
local cs = A.getCourses()
check(#cs == 3, 'courses listed: ' .. #cs .. ' (forward, reverse, sprint)')
local fwd, rev, spr = courseBy('qr_test_loop'), courseBy('qr_test_loop_rev'), courseBy('qr_top_sprint')
check(fwd and fwd.name == 'Test loop' and rev and rev.name == 'Test loop (reverse)', 'names: ' .. tostring(fwd and fwd.name) .. ' / ' .. tostring(rev and rev.name))
check(fwd and fwd.closed and abs(fwd.length - loop.len) < 0.02 * loop.len, string.format('forward line %s m along the graph (loop %.0f m)', tostring(fwd and fwd.length), loop.len))
check(rev and abs(rev.length - loop.len) < 0.02 * loop.len, 'reverse line ' .. tostring(rev and rev.length) .. ' m')
check(fwd and fwd.checkpoints == 4 and rev and rev.checkpoints == 4, 'checkpoints: 4 each (' .. tostring(fwd and fwd.checkpoints) .. ', ' .. tostring(rev and rev.checkpoints) .. ')')
check(fwd and not fwd.enabled and not rev.enabled and not fwd.approx, 'off by default, no straight-line legs')
check(spr and not spr.closed and abs(spr.length - 340) < 10 and spr.checkpoints == 2, 'race.json sprint: ' .. tostring(spr and spr.length) .. ' m, ' .. tostring(spr and spr.checkpoints) .. ' checkpoints')
local rf, rr = routeBy('qr_test_loop'), routeBy('qr_test_loop_rev')
check(rf and rr and rf.start.nx > 0.99 and rr.start.nx < -0.99, string.format('gates face the driving direction (%.2f, %.2f)', rf and rf.start.nx or 0, rr and rr.start.nx or 0))
local maxOff = 0
for i = 1, #rf.pts, 7 do
  local d = dOf(loop, rf.pts[i][1], rf.pts[i][2])
  local x, y = at(loop, d)
  maxOff = math.max(maxOff, sqrt((x - rf.pts[i][1]) ^ 2 + (y - rf.pts[i][2]) ^ 2))
end
check(maxOff < 3, string.format('the line stays on the road, not out to the spur and back (max %.2f m off; the graph cuts the arcs with 21 m chords)', maxOff))
check(abs(rf.ccp[1] - 100) < 4, string.format('the spur checkpoint sits on the line beside it (station %.0f, expected 100)', rf.ccp[1]))
local c2 = rr.ccp and rr.ccp[3] -- reversed order: 4, 3, 2, 1; the reverse prefab moves Checkpoint_2 to 690 m
local e1, e0 = (200 - 690) % loop.len, (200 - 700) % loop.len
check(c2 and abs(c2 - e1) < 5 and abs(c2 - e1) < abs(c2 - e0), string.format('reverse prefab overrides a checkpoint (station %.0f: moved %.0f, base %.0f)', c2 or -1, e1, e0))

-- 2. disabled: driving the course times nothing ---------------------------------------------
drive(loop, 100, 200 + loop.len * 1.3, V)
check(#lapsOn('qr_test_loop') == 0 and not A.isLapActive() and courseBy('qr_test_loop').laps == 0, 'disabled course: no lap')

-- 3. enabled: laps with every checkpoint, and discovery leaves the loop to the course ---------
newLevel('t_course')
check(A.setCourseEnabled('qr_test_loop', true) and courseBy('qr_test_loop').enabled, 'setCourseEnabled(forward, true)')
local mark = #LAPS + 1
drive(loop, 100, 200 + loop.len * 3 + 30, V)
local ls = lapsOn('qr_test_loop', mark)
check(#ls == 3, '3 laps on the course (' .. #ls .. ')')
for i, l in ipairs(ls) do
  check(l.valid and abs(l.time - loop.len / V) < 0.3 and l.checkpoints and l.checkpoints.passed == 4 and l.checkpoints.total == 4,
    string.format('lap %d %s (expected %.3f)', i, fmt(l), loop.len / V))
end
check(ls[1] and ls[1].name == 'Test loop', 'lap info carries the course name')
check(#A.getRoutes() == 0, 'no found route duplicates the course (' .. #A.getRoutes() .. ')')
check(A.isLapActive() and A.getState().active.courseTotal == 4, 'lap 4 under way')

-- 4. kept across a restart; official courses can't be deleted -----------------------------
newLevel('t_course')
fwd = courseBy('qr_test_loop')
check(fwd.enabled and fwd.laps == 3 and fwd.best and abs(fwd.best - loop.len / V) < 0.3, 'restart: enabled, 3 laps, best ' .. tostring(fwd.best))
check(not courseBy('qr_test_loop_rev').enabled, 'restart: reverse still off')
check(A.clearRoute('qr_test_loop') == false and courseBy('qr_test_loop'), 'clearRoute refuses an official course')
local saved = readJSON('settings/coDriverCoach/routes/t_course.json')
local entry
for _, r in ipairs(saved and saved.routes or {}) do if r.id == 'qr_test_loop' then entry = r end end
check(entry and entry.source == 'official' and entry.pts == nil and entry.enabled == true, 'routes file keeps the state, not the line')

-- 5. the other way round: a different course ------------------------------------------------
local back = {}
for i = #loop.pts, 1, -1 do back[#back + 1] = loop.pts[i] end
back = prep(back, true)
local fx, fy = at(loop, 200)
local dF = dOf(back, fx, fy)
mark = #LAPS + 1
drive(back, dF - 100, dF + back.len * 2.6, V)
check(#lapsOn('qr_test_loop', mark) == 0 and #lapsOn('qr_test_loop_rev', mark) == 0, 'reverse direction, reverse course off: no lap on either')
local found = A.getRoutes()
check(#found == 1 and not found[1].course, 'reverse direction: discovery found the loop itself (the course is off)')
check(A.setCourseEnabled('qr_test_loop_rev', true) and A.getRoutes()[1].course == 'qr_test_loop_rev', 'turning the reverse course on: the found loop defers to it')
mark = #LAPS + 1
drive(back, dF - 100, dF + back.len * 2 + 30, V)
ls = lapsOn('qr_test_loop_rev', mark)
check(#ls == 2 and #lapsOn(found[1].id, mark) == 0, 'reverse course: 2 laps, none on the found loop (' .. #ls .. ')')
for i, l in ipairs(ls) do
  check(l.valid and abs(l.time - back.len / V) < 0.3 and l.checkpoints.passed == 4, string.format('reverse lap %d %s', i, fmt(l)))
end
check(#lapsOn('qr_test_loop', mark) == 0, 'reverse laps: none on the forward course')

-- 6. crossing the course without following it starts no lap ----------------------------------
newLevel('t_course')
local cross = prep({ { 200 - 300 * cx, -40 - 300 * cy, 0 }, { 200 + 300 * cx, -40 + 300 * cy, 0 } }, false)
local started = false
mark = #LAPS + 1
drive(cross, 0, 600, 20, function() started = started or A.isLapActive() end)
check(not started, 'a street crossing the finish line at 60 degrees: no lap')
local across = prep({ { 300, 400, 0 }, { 300, 0, 0 } }, false)
drive(across, 0, 400, 20, function() started = started or A.isLapActive() end)
check(not started and #LAPS == mark - 1, 'driving across the circuit: no lap')

-- 7. turning a course off stops its lap ------------------------------------------------------
drive(loop, 100, 600, V)
check(A.isLapActive(), 'lap under way on the forward course')
A.setCourseEnabled('qr_test_loop', false)
check(not A.isLapActive() and not courseBy('qr_test_loop').enabled, 'turned off: the lap stops, nothing more is timed')

print(fails == 0 and 'ALL PASSED' or (fails .. ' FAILED'))
