-- Synthetic corner: 100 m straight, 90 degree left (R 20 m), 100 m straight. Road graph half-width
-- 6 m; walls (MODE 'walls') at 3 m inside and 4 m outside, or (MODE 'post') a single post at the apex.
local MODE = MODE or 'walls' -- env MODE=walls/post/post2/none
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
if MODE == 'walls' then
  for _, s in ipairs(offsetLine(3)) do MOCK_WALLS[#MOCK_WALLS + 1] = s end
  for _, s in ipairs(offsetLine(-4)) do MOCK_WALLS[#MOCK_WALLS + 1] = s end
elseif MODE == 'post2' then
  -- a thin 0.2 m post between two grid radials, deep inside (where the free line wants to be)
  local th = 0.7
  local cx, cy = 100 + 15.8 * math.sin(th), 20 - 15.8 * math.cos(th)
  local h = 0.1
  MOCK_WALLS = { { cx - h, cy - h, cx + h, cy - h }, { cx + h, cy - h, cx + h, cy + h }, { cx + h, cy + h, cx - h, cy + h }, { cx - h, cy + h, cx - h, cy - h } }
elseif MODE == 'post' then
  -- 0.6 m square post 2.2 m inside the centreline at the apex (45 degrees)
  local th = math.pi / 4
  local cx, cy = 100 + (20 - 2.5) * math.sin(th), 20 - (20 - 2.5) * math.cos(th)
  local h = 0.3
  MOCK_WALLS = { { cx - h, cy - h, cx + h, cy - h }, { cx + h, cy - h, cx + h, cy + h }, { cx + h, cy + h, cx - h, cy + h }, { cx - h, cy + h, cx - h, cy - h } }
end
-- road graph every ~5 m
local id = 0
for i = 1, #route, 10 do
  id = id + 1
  MOCK_NODES[id] = { pos = vec3(route[i][1], route[i][2], 0), radius = 6 }
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
  samples[#samples + 1] = { t, x, y, 0.35, v * math.cos(h), v * math.sin(h), 0, math.cos(h), math.sin(h), thr, brk, 0, 3, 5000, 0, brk, v, 1, 1 }
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
-- how close does the better line get to the walls / post? lateral offset of the ideal line
local minWall = math.huge
for i = 1, #P.ix do
  for _, w in ipairs(MOCK_WALLS) do
    -- distance point-segment
    local x1, y1, x2, y2 = w[1], w[2], w[3], w[4]
    local ex, ey = x2 - x1, y2 - y1
    local f = math.max(0, math.min(1, ((P.ix[i] - x1) * ex + (P.iy[i] - y1) * ey) / (ex * ex + ey * ey)))
    local dd = math.sqrt((P.ix[i] - x1 - ex * f) ^ 2 + (P.iy[i] - y1 - ey * f) ^ 2)
    if dd < minWall then minWall = dd end
  end
end
-- offsets at the apex region
local apexOff = {}
for i = 1, #P.ix do
  if P.s[i] >= 200 and P.s[i] <= 232 then
    local x, y = P.ix[i] - 100, P.iy[i] - 20
    apexOff[#apexOff + 1] = string.format('%.1f', 20 - math.sqrt(x * x + y * y)) -- + = inside
  end
end
print(MODE, 'points', #P.ix, 'min distance from the better line to a wall', string.format('%.2f', minWall), 'clipFixes', R.model.clipFixes)
print('inside offset through the corner (m):', table.concat(apexOff, ' '))
print('gap', R.gap, 'ideal min speed', R.corners[1] and R.corners[1].idealMin, 'model', jsonEncode(R.model))
