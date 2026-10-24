-- Slope test: the t_walls corner (100 m straight, 90 degree left R 20 m, 100 m straight, 6 m road) with the
-- approach on a grade. MODE=flat|down|up (8% down or up toward the corner; level from the corner on).
-- Prints the ideal brake point and corner speed, and the car model, to check gravity is in the model.
local MODE = MODE or 'down'
local SLOPE = ({ flat = 0, down = -0.08, up = 0.08 })[MODE] or 0
-- ground height: on the grade until the corner starts (x = 100), level after it
local function zg(x, y) return SLOPE * (math.min(x, 100) - 100) end
local baseRay = castRayStatic
function castRayStatic(o, d, maxDist)
  if d.z < -0.5 then
    RAYS = RAYS + 1
    local t = (o.z - zg(o.x, o.y)) / -d.z
    return (t >= 0 and t < maxDist) and t or maxDist
  end
  return baseRay(o, d, maxDist)
end
local route = {}
for d = -100, 100, 0.5 do route[#route + 1] = { 0 + d, 0, 0 } end -- x, y, heading
for th = 0.025, math.pi / 2, 0.025 do route[#route + 1] = { 100 + 20 * math.sin(th), 20 - 20 * math.cos(th), th } end
for d = 0.5, 200, 0.5 do route[#route + 1] = { 120, 20 + d, math.pi / 2 } end
-- offset polyline (left positive)
local function offsetLine(off)
  local pts = {}
  for i, p in ipairs(route) do pts[i] = { p[1] - math.sin(p[3]) * off, p[2] + math.cos(p[3]) * off } end
  local segs = {}
  for i = 1, #pts - 1 do segs[#segs + 1] = { pts[i][1], pts[i][2], pts[i + 1][1], pts[i + 1][2] } end
  return segs
end
MOCK_WALLS = {}
-- road graph every ~5 m
local id = 0
for i = 1, #route, 10 do
  id = id + 1
  MOCK_NODES[id] = { pos = vec3(route[i][1], route[i][2], zg(route[i][1], route[i][2])), radius = 6 }
  if id > 1 then MOCK_EDGES[#MOCK_EDGES + 1] = { id - 1, id } end
end
-- drive it on the centreline: 25 m/s, 14 m/s through the corner, at 60 Hz
local samples, t, d = {}, 0, 0
local function speedAt(dd) dd = dd - 100 if dd < 60 then return 25 elseif dd < 100 then return 25 - (dd - 60) / 40 * 11 elseif dd < 131 then return 14 else return math.min(25, 14 + (dd - 131) / 40 * 11) end end
local total = 200 + 20 * math.pi / 2 + 200
local function at(dd)
  dd = dd - 100
  if dd <= 100 then return dd, 0, 0 end
  if dd <= 100 + 10 * math.pi then local th = (dd - 100) / 20 return 100 + 20 * math.sin(th), 20 - 20 * math.cos(th), th end
  return 120, 20 + (dd - 100 - 10 * math.pi), math.pi / 2
end
while d < total - 1 do
  local v = speedAt(d)
  local x, y, h = at(d)
  local brk = (d > 160 and d < 200) and 0.6 or 0
  local thr = (d > 231 or d < 160) and 1 or 0.1
  local vz = (x < 100 and h == 0) and v * SLOPE or 0
  samples[#samples + 1] = { t, x, y, zg(x, y) + 0.35, v * math.cos(h), v * math.sin(h), vz, math.cos(h), math.sin(h), thr, brk, 0, 3, 5000, 0, brk, v, 1, 1 }
  t = t + 1 / 60
  d = d + v / 60
end
local sess = { date = 'test', level = 'test', fmt = 2, parts = {}, samples = samples,
  car = { halfWidth = 0.95, mass = 1200, powerKW = 150, brakeN = 18000, driven = 'RWD', abs = true } }
writeText('settings/coDriverCoach/last_session.json', jsonEncode(sess))
A.loadLast()
local R = A.getResult()
if R.error then print('ERROR', R.error) return end
local P = R.points
local c = R.corners[1]
for _, cc in ipairs(R.corners) do if not cc.unneeded then c = cc break end end
local sBrake = c and P.s[c.iBrakeIdeal] or -1
print(string.format('%-5s ideal brake point at %.0f m (corner starts at 200 m), ideal min %.1f m/s, brake-zone grade %s%%, gap %.1f s',
  MODE, sBrake, c and c.idealMin or -1, c and tostring(c.gradePct) or '-', R.gap))
print('      model ' .. jsonEncode(R.model))
