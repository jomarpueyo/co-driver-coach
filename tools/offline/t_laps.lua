-- Lap and route recognition (coDriverLaps.lua as A) on synthetic tracks, driven through A.step at
-- 60 fps. Run it from an empty folder: it writes settings/coDriverCoach/routes/<level>.json there.
--   node tools/offline/run.js co_driver_coach/lua/ge/extensions/coDriverLaps.lua tools/offline/t_laps.lua
local pi, sin, cos, sqrt, abs = math.pi, math.sin, math.cos, math.sqrt, math.abs
local DT = 1 / 60
local fails = 0
local function check(ok, what)
  print((ok and 'ok   ' or 'FAIL ') .. what)
  if not ok then fails = fails + 1 end
end

-- a polyline every ~1 m from a parametric curve f(u), u in [0, 1]
local function curve(f, n)
  local pts = {}
  for i = 0, n do
    local x, y, z = f(i / n)
    pts[#pts + 1] = { x, y, z or 0 }
  end
  return pts
end

local function prep(pts, closed)
  local s = { 0 }
  for i = 2, #pts do s[i] = s[i - 1] + sqrt((pts[i][1] - pts[i - 1][1]) ^ 2 + (pts[i][2] - pts[i - 1][2]) ^ 2 + (pts[i][3] - pts[i - 1][3]) ^ 2) end
  local len = s[#pts]
  if closed then len = len + sqrt((pts[1][1] - pts[#pts][1]) ^ 2 + (pts[1][2] - pts[#pts][2]) ^ 2) end
  return { pts = pts, s = s, len = len, closed = closed }
end

-- position and direction at distance d along a path (wraps on closed paths)
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
  local dx, dy, dz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
  local l = sqrt(dx * dx + dy * dy + dz * dz)
  if l == 0 then l = 1 end
  return a[1] + dx * f, a[2] + dy * f, a[3] + dz * f, dx / l, dy / l, dz / l
end

-- drive from distance d0 to d1 along a path at speed v
local function drive(p, d0, d1, v)
  local d = d0
  while d < d1 do
    local x, y, z, ux, uy, uz = at(p, d)
    A.step(DT, x, y, z, ux * v, uy * v, uz * v, ux, uy)
    d = d + v * DT
  end
end

local function routes() return A.getRoutes() end
local function lapsOf(id)
  for _, r in ipairs(A._routes()) do if r.id == id then return r.laps end end
  return {}
end
local function fmt(l) return string.format('%.3f%s', l.time, l.valid and '' or (' invalid: ' .. tostring(l.reason))) end
local function newLevel(name) MOCK_LEVEL = name A._reset(name) end

-- 1. a rounded rectangle, three laps -------------------------------------------------
local function rect(w, h, r)
  local pts = {}
  local function arc(cx, cy, a0)
    for i = 0, 15 do local a = a0 + i / 15 * pi / 2 pts[#pts + 1] = { cx + r * cos(a), cy + r * sin(a), 0 } end
  end
  for x = 0, w, 2 do pts[#pts + 1] = { x, -r, 0 } end           -- bottom, heading east
  arc(w, 0, -pi / 2)
  for y = 0, h, 2 do pts[#pts + 1] = { w + r, y, 0 } end
  arc(w, h, 0)
  for x = w, 0, -2 do pts[#pts + 1] = { x, h + r, 0 } end
  arc(0, h, pi / 2)
  for y = h, 0, -2 do pts[#pts + 1] = { -r, y, 0 } end
  arc(0, 0, pi)
  return pts
end
newLevel('t_loop')
local loop = prep(rect(400, 200, 40), true)
local V = 25
local start = 200 -- metres along the path: the middle of the bottom straight
drive(loop, start, start + loop.len * 1.5, V)
check(#routes() == 0, string.format('loop (%.0f m): nothing saved while lap 2 confirms it', loop.len))
drive(loop, start + loop.len * 1.5, start + loop.len * 3 + 60, V)
local rs = routes()
check(#rs == 1 and rs[1].closed, 'loop: one closed route after 3 laps')
local id = rs[1] and rs[1].id
local laps = lapsOf(id)
local expect = loop.len / V
check(rs[1] and abs(rs[1].len - loop.len) < 0.02 * loop.len, string.format('loop: route %.0f m (driven %.0f m)', rs[1] and rs[1].len or 0, loop.len))
check(#laps == 3, 'loop: 3 laps recorded (' .. #laps .. ')')
for i, l in ipairs(laps) do
  check(l.valid and abs(l.time - expect) < 0.3, string.format('loop: lap %d %s (expected %.3f)', i, fmt(l), expect))
end
check(A.isLapActive(), 'loop: lap 4 under way')

-- 2. the saved route after a restart: laps start at its gate, live delta against the best ----
A._reset('t_loop')
check(#routes() == 1, 'restart: route loaded from file')
drive(loop, start - 300, start + 400, V)
for _ = 1, 120 do A.step(0, at(loop, start + 400)) end -- paused 2 s: doesn't count
drive(loop, start + 400, start + loop.len + 80, V)
laps = lapsOf(id)
local l = laps[#laps]
check(#laps == 4 and l.valid and abs(l.time - expect) < 0.3, 'restart: lap from the saved gate ' .. (l and fmt(l) or '-'))
local st = A.getState()
check(st.lastLap and st.lastLap.deltaBest and abs(st.lastLap.deltaBest) < 0.3, 'restart: delta to best ' .. tostring(st.lastLap and st.lastLap.deltaBest))

-- 3. the same loop backwards: no laps on it ------------------------------------------------
A._reset('t_loop')
local rev = {}
for i = #loop.pts, 1, -1 do rev[#rev + 1] = loop.pts[i] end
local back = prep(rev, true)
drive(back, 0, back.len * 0.9, V)
check(not A.isLapActive() and #lapsOf(id) == 4, 'reverse: no lap on the forward route')

-- 4. a detour on lap 3: invalid, lap 4 valid again ------------------------------------------
newLevel('t_detour')
drive(loop, start, start + loop.len * 2 + 1, V)
local det = {}
for i, p in ipairs(loop.pts) do
  local d = (loop.s[i] - start) % loop.len
  local off = 0
  if d > 500 and d < 850 then off = 50 * math.min(1, (d - 500) / 40, (850 - d) / 40) end
  det[#det + 1] = { p[1], p[2] - off, p[3] }                -- the bottom straight and its corner, pushed south
end
local detour = prep(det, true)
-- the start point is before the detour, so it is the same distance along both paths
drive(detour, start + 1, start + detour.len, V)
drive(loop, start, start + loop.len + 60, V)
rs = routes()
laps = rs[1] and lapsOf(rs[1].id) or {}
check(#rs == 1 and #laps == 4, 'detour: one route, 4 laps (' .. #laps .. ')')
check(laps[3] and not laps[3].valid and laps[3].reason == 'left the route', 'detour: lap 3 ' .. (laps[3] and fmt(laps[3]) or '-'))
check(laps[4] and laps[4].valid, 'detour: lap 4 ' .. (laps[4] and fmt(laps[4]) or '-'))

-- 5. a roundabout, 12 times round: no route ----------------------------------------------
newLevel('t_round')
local round = prep(curve(function(u) return 20 * cos(2 * pi * u), 20 * sin(2 * pi * u) end, 125), true)
drive(round, 0, round.len * 12, 12)
check(#routes() == 0 and not A.isLapActive(), 'roundabout: no route')

-- 6. out and back once: no route -----------------------------------------------------------
newLevel('t_oab')
local oab = {}
for x = 0, 900, 2 do oab[#oab + 1] = { x, 0, 0 } end
for i = 1, 15 do local a = -pi / 2 + i / 16 * pi oab[#oab + 1] = { 900 + 10 * cos(a), 10 + 10 * sin(a), 0 } end
for x = 900, 0, -2 do oab[#oab + 1] = { x, 20, 0 } end
local oabp = prep(oab, false)
drive(oabp, 0, oabp.s[#oabp.s], 20)
check(#routes() == 0, 'out and back: no route')

-- 7. a figure of eight crossing at grade: the whole figure is the route -----------------------
newLevel('t_fig8')
local fig8 = prep(curve(function(u)
  local t = 2 * pi * u
  local d = 1 + sin(t) ^ 2
  return 305 * cos(t) / d, 305 * sin(t) * cos(t) / d
end, 1700), true)
drive(fig8, 10, 10 + fig8.len * 3 + 60, 20)
rs = routes()
check(#rs == 1 and abs(rs[1].len - fig8.len) < 0.02 * fig8.len, string.format('figure 8: one route of %.0f m (figure %.0f m)', rs[1] and rs[1].len or 0, fig8.len))
laps = rs[1] and lapsOf(rs[1].id) or {}
check(#laps == 3 and laps[3].valid and abs(laps[3].time - fig8.len / 20) < 0.3, 'figure 8: 3 laps, lap 3 ' .. (laps[3] and fmt(laps[3]) or '-'))

-- 8. a helix: same place and direction 10 m higher: no route ---------------------------------
newLevel('t_helix')
local helix = prep(curve(function(u) return 150 * cos(4 * pi * u), 150 * sin(4 * pi * u), 20 * u end, 1900), false)
drive(helix, 0, helix.s[#helix.s], 20)
check(#routes() == 0, 'helix (overpass): no route')

-- 9. point to point, reset back to the start twice ------------------------------------------
newLevel('t_p2p')
local p2p = prep(curve(function(u) return 1400 * u, 120 * sin(u * 4 * pi) end, 1500), false)
local pend = p2p.s[#p2p.s]
drive(p2p, 0, pend, 20)
check(#routes() == 0, string.format('p2p (%.0f m): nothing after one run', pend))
drive(p2p, 0, 400, 20)                                          -- teleported back to the start
rs = routes()
check(#rs == 1 and not rs[1].closed and A.isLapActive(), 'p2p: route found on the second run, lap timed')
drive(p2p, 400, pend + 5, 20)
laps = rs[1] and lapsOf(rs[1].id) or {}
check(#laps == 1 and laps[1].valid and abs(laps[1].time - pend / 20) < 0.4, string.format('p2p: run 2 %s (expected about %.3f)', laps[1] and fmt(laps[1]) or '-', pend / 20))
check(not A.isLapActive(), 'p2p: stopped at the finish')
drive(p2p, 0, 600, 20)                                          -- and again, with a reset on the way
A.onVehicleResetted(nil)
drive(p2p, 600, pend + 5, 20)
laps = lapsOf(rs[1].id)
check(#laps == 2 and not laps[2].valid and laps[2].reason == 'car reset', 'p2p: run 3 ' .. (laps[2] and fmt(laps[2]) or '-'))

-- 10. manual start and finish -----------------------------------------------------------
newLevel('t_manual')
local m = prep(curve(function(u) return 600 * u, 40 * sin(u * 2 * pi) end, 620), false)
drive(m, 0, 50, 15)
A.markStart()
drive(m, 50, 550, 15)
A.markFinish()
rs = routes()
laps = rs[1] and lapsOf(rs[1].id) or {}
check(#rs == 1 and #laps == 1 and abs(laps[1].time - 500 / 15) < 0.3, 'manual: route and run ' .. (laps[1] and fmt(laps[1]) or '-'))

-- 11. a teleport whose first frame reports a huge speed, and a lap left parked off the route ----
newLevel('t_loop')
drive(loop, start - 100, start + 300, V)                        -- a lap on the saved loop
check(A.isLapActive(), 'teleport: lap under way')
A.step(DT, 5000, 5000, 0, 5000 / DT, 0, 0, 1, 0)                -- teleported far away, velocity spike
check(not A.isLapActive(), 'teleport: lap dropped despite the velocity spike')
drive(loop, start - 100, start + 300, V)                        -- another lap, then parked 60 m off the route
check(A.isLapActive(), 'parked: lap under way')
local px, py, pz = at(loop, start + 300)
for _ = 1, 60 * 40 do A.step(DT, px, py - 60, pz, 0, 0, 0, 1, 0) end
check(not A.isLapActive(), 'parked off the route for 40 s: lap dropped')
check(A.clearLaps(A.getRoutes()[1].id) and #lapsOf(A.getRoutes()[1].id) == 0, 'clearLaps: laps and best forgotten')

-- 12. a saved route with a repeated stretch (a reset while its lap was recorded): repaired on load
local bt = {}
for d = 0, loop.len - 4, 4 do
  bt[#bt + 1] = { at(loop, d) }
  if math.abs(d - 700) < 2 then                                 -- put back 88 m, then on again
    for d2 = 612, 700, 4 do bt[#bt + 1] = { at(loop, d2) } end
  end
end
for i, p in ipairs(bt) do bt[i] = { p[1], p[2], p[3] } end
mkdirJS('settings/coDriverCoach/routes')
writeText('settings/coDriverCoach/routes/t_repair.json', jsonEncode({ version = 1, level = 't_repair',
  routes = { { id = 'r1', closed = true, source = 'auto', pts = bt } } }))
newLevel('t_repair')
rs = routes()
check(#rs == 1 and abs(rs[1].len - loop.len) < 0.02 * loop.len, string.format('repair: route %.0f m after load (loop %.0f m)', rs[1] and rs[1].len or 0, loop.len))
local saved = readJSON('settings/coDriverCoach/routes/t_repair.json')
check(saved and saved.routes[1] and math.abs(saved.routes[1].len - loop.len) < 0.02 * loop.len, 'repair: saved back to the file')

-- 13. a reset in the confirming lap (driven 3 m to the side), then clean laps: lap 1 is the last
-- pass, although the first pass is the closer match
newLevel('t_recent')
local side = {}
for i, p in ipairs(loop.pts) do side[i] = { p[1], p[2] + 3, p[3] } end
side = prep(side, true)
drive(loop, start, start + loop.len + 100, V)
drive(side, start + loop.len + 100, start + loop.len * 1.5, V)
A.onVehicleResetted(nil)                                        -- reset in place: lap 2 can't confirm the loop
drive(side, start + loop.len * 1.5, start + loop.len * 2 - 60, V)
drive(loop, start + loop.len * 2 - 60, start + loop.len * 4 + 60, V)
rs = routes()
laps = rs[1] and lapsOf(rs[1].id) or {}
check(#rs == 1, 'recent pass: route found once the loop repeats cleanly')
check(laps[1] and abs(laps[1].time - expect) < 0.5, string.format('recent pass: lap 1 %s (one lap, %.1f s; not %.1f s)', laps[1] and fmt(laps[1]) or '-', expect, 2 * expect))

-- 14. a reset that puts the car 60 m back during a long frame starts a new stretch (not a backtrack)
newLevel('t_backjump')
drive(loop, start, start + 300, V)
local bx, by, bz, ux, uy = at(loop, start + 240)
A.step(0.3, bx, by, bz, ux * 200, uy * 200, 0, ux, uy)          -- long frame, velocity spike
check(A.getState().seg == 2, 'reset 60 m back in a 0.3 s frame: new stretch (seg ' .. tostring(A.getState().seg) .. ')')

-- 15. a first pass, then parked on the road for 10 minutes before driving on: that lap 1 isn't timed
newLevel('t_parked')
drive(loop, start, start + 300, V)
local qx, qy, qz, qux, quy = at(loop, start + 300)
for _ = 1, 60 * 600 do A.step(DT, qx, qy, qz, 0, 0, 0, qux, quy) end
drive(loop, start + 300, start + loop.len * 3 + 60, V)
rs = routes()
laps = rs[1] and lapsOf(rs[1].id) or {}
check(#rs == 1 and laps[1] and laps[1].n == 1 and laps[1].valid and laps[2] and laps[2].n == 2, 'parked in lap 1: route found, the confirming lap counts as lap 1 ' .. (laps[1] and fmt(laps[1]) or '-'))
check(#laps >= 1 and laps[1].time < expect + 0.5, 'parked in lap 1: no 10-minute lap')

-- 16. the strip's sector split: through onUpdate with a mocked car, a lap 5% slower than the best
newLevel('t_loop')
local car = { x = 0, y = 0, z = 0, vx = 0, vy = 0, fx = 1, fy = 0 }
getPlayerVehicle = function()
  return { getId = function() return 1 end, getPosition = function() return vec3(car.x, car.y, car.z) end,
    getVelocity = function() return vec3(car.vx, car.vy, 0) end, getDirectionVector = function() return vec3(car.fx, car.fy, 0) end }
end
local function driveUpd(p, d0, d1, v)
  local d = d0
  while d < d1 do
    local x, y, z, ux, uy = at(p, d)
    car.x, car.y, car.z, car.vx, car.vy, car.fx, car.fy = x, y, z, ux * v, uy * v, ux, uy
    A.onUpdate(DT, DT)
    d = d + v * DT
  end
end
local Vs = V * 0.95
driveUpd(loop, start - 100, start + loop.len + 1, V)            -- a lap at V: the best (test 11 cleared it)
driveUpd(loop, start + loop.len + 1, start + loop.len * 4 / 3 + 30, Vs)
local ui = GUI.CoDriverLaps or {}
check(ui.sector and ui.sector.k == 1 and ui.sector.delta and ui.sector.delta > 0, 'sector split after a third: S' .. tostring(ui.sector and ui.sector.k) .. ' ' .. tostring(ui.sector and ui.sector.delta))
local expectS1 = loop.len / 3 / Vs - loop.len / 3 / V
check(ui.sector and math.abs(ui.sector.delta - expectS1) < 0.4, string.format('S1 gap %.2f (expected about %.2f)', ui.sector and ui.sector.delta or -1, expectS1))
driveUpd(loop, start + loop.len * 4 / 3 + 30, start + loop.len * 5 / 3 + 30, V)
ui = GUI.CoDriverLaps or {}
check(ui.sector and ui.sector.k == 2 and math.abs(ui.sector.delta) < 0.4, 'S2 at the best pace: ' .. tostring(ui.sector and ui.sector.delta))

-- 17. the ghost: a best lap 10% quicker than this one (a mocked coDriverAnalysis file, from the
-- start line round the loop); during a lap it is where that lap was at the same lap time
local Vg = V * 1.1
local gp = { x = {}, y = {}, z = {}, t = {} }
for d = 0, loop.len, 4 do
  local x, y, z = at(loop, start + d)
  local k = #gp.x + 1
  gp.x[k], gp.y[k], gp.z[k], gp.t[k] = x, y, z, d / Vg
end
coDriverAnalysis = { loadBestEver = function(lvl, id) return { time = loop.len / Vg, pts = gp } end }
newLevel('t_loop')
driveUpd(loop, start - 100, start + 300, V)                     -- on the saved loop: a lap started at the line
local T = 300 / V                                               -- seconds since the line
local gx, gy = A._ghostAt(T)
local ex, ey = at(loop, start + T * Vg)
check(gx and math.sqrt((gx - ex) ^ 2 + (gy - ey) ^ 2) < 3, string.format('ghost %.1f m from where the best lap was (%.0f m ahead of the car)', gx and math.sqrt((gx - ex) ^ 2 + (gy - ey) ^ 2) or -1, T * (Vg - V)))
check(A._ghostAt(loop.len / Vg + 5) == nil, 'no ghost past the end of its lap')
check(A.setOption('ghost', 'line') and not A.setOption('ghost', 'sideways'), 'ghost option: off / marker / line only')
coDriverAnalysis = nil

print(fails == 0 and 'ALL PASSED' or (fails .. ' FAILED'))
