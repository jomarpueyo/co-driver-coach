-- Co-Driver Coach: automatic lap and route recognition in free roam (docs/PROJECT_REVIEW.md §5.1).
-- * The drive leaves a trail of breadcrumbs (every 4 m) in a spatial hash.
-- * Loops: coming back onto your own trail in the same direction, 600 m and 30 s later, and
--   following it for 150 m closes a loop. The loop becomes a route with a start gate where you
--   rejoined the trail; the lap just closed counts as lap 1 and lap 2 starts.
-- * Point to point: after a teleport or reset back to where an earlier run started, following that
--   run for 300 m makes a route from its start to where it ended.
-- * Manual: markStart() / markFinish() (hotkeys) for any start and finish.
-- * A lap is valid with 90% of the checkpoints (every 100 m) passed in order, a driven distance
--   within 15% of the route, no reset, and no more than 3 s or 150 m off the route.
-- * Official courses: the level's quick race layouts (coDriverLaps/courses.lua), forward and
--   reverse, listed by getCourses() and timed only once turned on with setCourseEnabled(id, true).
--   A valid lap on one also passes every checkpoint of the course.
-- Routes are saved per level in settings/coDriverCoach/routes/<level>.json with their best lap
-- (splits every 20 m for a live delta) and recent laps. Lap times follow simulation time, so
-- pauses don't count. step() takes plain numbers, so the offline tests can drive it.
local M = {}
local logTag = 'coDriverLaps'
local floor, max, min, abs, sqrt, cos, rad = math.floor, math.max, math.min, math.abs, math.sqrt, math.cos, math.rad

local SETTINGS = 'settings/coDriverCoach/laps_settings.json'
local ROUTES_DIR = 'settings/coDriverCoach/routes/'
-- discovery: auto = time a route as soon as it is found, off = saved and marked routes only;
-- ghost: where your best lap on this route was at the same lap time, off / marker / line (marker
-- plus the best lap's line for the next 200 m)
local defaults = { discovery = 'auto', ghost = 'off' }

local CRUMB_DS = 4               -- breadcrumb spacing (m)
local CELL = 25                  -- spatial hash cell (m); searches look at the 3 x 3 cells around a point
local MATCH_R, FOLLOW_R = 8, 10  -- back on a trail: within 8 m to start, 10 m while following it
local HEAD_COS = cos(rad(30))    -- same direction: within 30 degrees
local DZ_MAX = 4                 -- height difference allowed (overpasses are further apart)
local MIN_LOOP_S, MIN_LOOP_T = 600, 30 -- a loop is at least this long (m, s)
local SHORT_LOOP_S = 100         -- passing here in the same direction less than MIN_LOOP_S ago means a smaller loop (a roundabout)
local CONFIRM_S, P2P_CONFIRM_S = 150, 300 -- how far a match must hold before a route is made (m)
local P2P_START_R = 30           -- a run starting this close to an earlier run's start may repeat it
local TELEPORT_M = 25            -- a jump this far in one frame is a teleport or reset to elsewhere
local CP_DS, SPLIT_DS = 100, 20  -- checkpoint and best-lap split spacing (m)
local OFF_T, OFF_S = 3, 150      -- off the route longer or further than this: the lap is invalid
local ABANDON_T, ABANDON_S = 30, 600 -- and this: the lap is abandoned
local KEEP_PARTIAL = 0.25        -- abandoned laps that covered this share of the route are kept (invalid)
local DEBOUNCE = 3               -- seconds between gate crossings
local LAP1_MIN_V = 5             -- a found loop's first lap slower than this on average (m/s) had stops in it: not timed
local TICK = 0.1                 -- matching rate (s)
local MAX_CRUMBS = 100000        -- 400 km; the trail starts over after that
local MAX_LAPS = 30              -- laps kept per route

package.loaded['coDriverLaps/courses'] = nil -- reloading picks up a new copy
local okLib, courseLib = pcall(require, 'coDriverLaps/courses')
if not okLib then log('E', logTag, 'official courses unavailable: ' .. tostring(courseLib)) courseLib = nil end

local cfg = {}
local clock = 0                  -- simulation seconds
local level = nil
local routes = {}                -- this level's routes
local trail, seg = nil, 0        -- breadcrumbs; seg counts unbroken stretches (teleports start a new one)
local cand = nil                 -- a return to the trail being confirmed
local p2pWatch = nil             -- a new stretch started: check whether it repeats an earlier run
local marks = nil                -- manual start mark
local active = nil               -- { route, lap }
local lastPos = nil              -- { x, y, z }
local lastHx, lastHy = nil, nil  -- heading (unit, horizontal)
local resets = {}                -- times of in-place resets (a lap containing one is invalid)
local lastLap = nil              -- the last finished lap, shown for a few seconds
local tickAcc, tickDs, uiAcc, uiWasActive = 0, 0, 0, false
local vehId = nil
local courseState = {}           -- saved state (enabled, best, laps) of official courses not built yet, by id
local coursesLevel = nil         -- the level whose official courses are built
local courseWait = 0             -- frames waited for the road graph before building them
local courseQueue = nil          -- courses still to build: { level, list, i, n, ms }, one per frame

local function round(v, d) local m = 10 ^ (d or 1) return floor(v * m + 0.5) / m end
local function cellKey(x, y) return (floor(x / CELL) + 32768) * 65536 + (floor(y / CELL) + 32768) end
-- official courses time laps only once turned on; a route of the driver's that an enabled course
-- covers leaves its laps to the course
local function timed(r) return (r.source ~= 'official' or r.enabled == true) and not r.shadow end

local function notify(msg)
  log('I', logTag, msg)
  if ui_message then pcall(ui_message, msg, 6, 'coDriverLaps', 'timer') end
end

local function loadSettings()
  local s = FS:fileExists(SETTINGS) and jsonReadFile(SETTINGS) or {}
  for k, v in pairs(defaults) do cfg[k] = (type(s) == 'table' and s[k] ~= nil) and s[k] or v end
end

-- trail ---------------------------------------------------------------------------

local function newTrail()
  return { n = 0, x = {}, y = {}, z = {}, hx = {}, hy = {}, s = {}, t = {}, seg = {}, cells = {}, segStart = {}, segEnd = {} }
end

local function dropCrumb(x, y, z, hx, hy)
  local tr = trail
  local n = tr.n
  local ds = 0
  if n > 0 and tr.seg[n] == seg then
    local dx, dy = x - tr.x[n], y - tr.y[n]
    ds = sqrt(dx * dx + dy * dy)
    if ds < CRUMB_DS then return end
  end
  if n >= MAX_CRUMBS then
    trail, cand, p2pWatch, marks = newTrail(), nil, nil, nil
    tr, n, ds = trail, 0, 0
  end
  n = n + 1
  tr.n = n
  tr.x[n], tr.y[n], tr.z[n], tr.hx[n], tr.hy[n] = x, y, z, hx, hy
  tr.s[n] = (n > 1 and tr.s[n - 1] or 0) + ds
  tr.t[n], tr.seg[n] = clock, seg
  if not tr.segStart[seg] then tr.segStart[seg] = n end
  tr.segEnd[seg] = n
  local k = cellKey(x, y)
  local list = tr.cells[k]
  if not list then list = {} tr.cells[k] = list end
  list[#list + 1] = n
end

-- calls fn(i) for every point index in the cells around (x, y) of a hash
local function eachNear(cells, x, y, fn)
  local cx, cy = floor(x / CELL), floor(y / CELL)
  for ix = cx - 1, cx + 1 do
    for iy = cy - 1, cy + 1 do
      local list = cells[(ix + 32768) * 65536 + (iy + 32768)]
      if list then for k = 1, #list do fn(list[k]) end end
    end
  end
end

local function crumbMatch(j, x, y, z, hx, hy, r)
  local tr = trail
  local dx, dy = tr.x[j] - x, tr.y[j] - y
  local d = dx * dx + dy * dy
  if d <= r * r and abs(tr.z[j] - z) <= DZ_MAX and tr.hx[j] * hx + tr.hy[j] * hy >= HEAD_COS then return d end
end

-- times at every SPLIT_DS of trail distance from s0 (time origin t0), along crumbs i1..i2
local function trailSplits(i1, i2, t0, s0)
  local tr, out, k = trail, {}, 1
  for i = max(i1 + 1, 2), i2 do
    local sa, sb = tr.s[i - 1] - s0, tr.s[i] - s0
    while sb > sa and sb >= k * SPLIT_DS do
      local f = (k * SPLIT_DS - sa) / (sb - sa)
      out[k] = round(tr.t[i - 1] + (tr.t[i] - tr.t[i - 1]) * max(f, 0) - t0, 3)
      k = k + 1
    end
  end
  return out
end

local function resetBetween(t0, t1)
  for _, t in ipairs(resets) do if t > t0 and t <= t1 then return true end end
  return false
end

-- routes ------------------------------------------------------------------------

local function roadHalfWidth(x, y, z)
  local ok, hw = pcall(function()
    local a = map.findBestRoad(vec3(x, y, z))
    local node = a and map.getMap().nodes[a]
    return node and node.radius
  end)
  return (ok and tonumber(hw)) and max(6, min(hw + 2, 14)) or 7
end

local function gateAt(p, nx, ny)
  return { x = p[1], y = p[2], z = p[3], nx = nx, ny = ny, hw = roadHalfWidth(p[1], p[2], p[3]) }
end

-- A reset during the lap a route was made from (the car put back a little way) leaves a jump in
-- the trail followed by the same stretch driven again: cut the repeat out, so the route covers
-- the road once (otherwise it is too long and its stations run ahead of a real lap).
local function removeBacktracks(p)
  local cut, i = 0, 1
  while i < #p do
    local b = p[i + 1]
    if sqrt((b[1] - p[i][1]) ^ 2 + (b[2] - p[i][2]) ^ 2) > 3 * CRUMB_DS then
      local bestJ, bestD = nil, (2 * CRUMB_DS) ^ 2
      for j = i, max(1, i - 200), -1 do
        local d = (p[j][1] - b[1]) ^ 2 + (p[j][2] - b[2]) ^ 2
        if d < bestD then bestJ, bestD = j, d end
      end
      if bestJ then
        for _ = bestJ + 1, i do table.remove(p, bestJ + 1) end
        cut, i = cut + 1, bestJ
      end
    end
    i = i + 1
  end
  return cut
end

local function prepareRoute(r)
  local p = r.pts
  r.repaired = removeBacktracks(p) > 0 or nil
  local n = #p
  r.s = { 0 }
  for i = 2, n do r.s[i] = r.s[i - 1] + sqrt((p[i][1] - p[i - 1][1]) ^ 2 + (p[i][2] - p[i - 1][2]) ^ 2) end
  r.len = r.s[n] + (r.closed and sqrt((p[1][1] - p[n][1]) ^ 2 + (p[1][2] - p[n][2]) ^ 2) or 0)
  r.tx, r.ty, r.cells = {}, {}, {}
  for i = 1, n do
    local a = p[i > 1 and i - 1 or (r.closed and n or 1)]
    local b = p[i < n and i + 1 or (r.closed and 1 or n)]
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local l = sqrt(dx * dx + dy * dy)
    r.tx[i], r.ty[i] = l > 0 and dx / l or 1, l > 0 and dy / l or 0
    local k = cellKey(p[i][1], p[i][2])
    r.cells[k] = r.cells[k] or {}
    table.insert(r.cells[k], i)
  end
  r.cps = {}
  local c = CP_DS
  while c < r.len - CP_DS / 2 do r.cps[#r.cps + 1] = c c = c + CP_DS end
  r.start = r.start or gateAt(p[1], r.tx[1], r.ty[1])
  if not r.closed then r.finish = r.finish or gateAt(p[n], r.tx[n], r.ty[n]) end
  r.offTol = max(12, r.start.hw + 6)
  r.laps = r.laps or {}
  return r
end

local function routesFile() return ROUTES_DIR .. tostring(level) .. '.json' end

local function saveRoutes()
  if not level or level == '' then return end
  local out = { version = 1, level = level, routes = {} }
  for _, r in ipairs(routes) do
    if r.source == 'official' then
      -- the line comes from the game's files at each level load; only what the driver did is kept
      if r.enabled or r.best or #r.laps > 0 then
        out.routes[#out.routes + 1] = { id = r.id, name = r.name, source = r.source, course = r.course, reverse = r.reverse,
          closed = r.closed, enabled = r.enabled, created = r.created, len = round(r.len), best = r.best, laps = r.laps }
      end
    else
      local pts = {}
      for i, p in ipairs(r.pts) do pts[i] = { round(p[1]), round(p[2]), round(p[3]) } end
      out.routes[#out.routes + 1] = { id = r.id, name = r.name, closed = r.closed, source = r.source, created = r.created,
        len = round(r.len), pts = pts, start = r.start, finish = r.finish, best = r.best, laps = r.laps }
    end
  end
  for _, s in pairs(courseState) do out.routes[#out.routes + 1] = s end
  if not FS:directoryExists(ROUTES_DIR) then FS:directoryCreate(ROUTES_DIR, true) end
  local ok, err = pcall(jsonWriteFile, routesFile(), out, false)
  if not ok then log('E', logTag, 'saving routes failed: ' .. tostring(err)) end
end

local function loadRoutes()
  routes, courseState, coursesLevel, courseWait, courseQueue = {}, {}, nil, 0, nil
  local f = level and level ~= '' and routesFile()
  local data = f and FS:fileExists(f) and jsonReadFile(f)
  if type(data) ~= 'table' or type(data.routes) ~= 'table' then return end
  for _, r in ipairs(data.routes) do
    if type(r) == 'table' and r.source == 'official' then
      if r.id then courseState[r.id] = r end
    elseif type(r) == 'table' and type(r.pts) == 'table' and #r.pts >= 2 then
      -- fields from the file that the timer relies on every frame: a bad one is dropped (the start
      -- line is then rebuilt from the route's first point), so a damaged file can't break timing
      local g = r.start
      if type(g) ~= 'table' or type(g.x) ~= 'number' or type(g.y) ~= 'number' or type(g.z) ~= 'number'
        or type(g.nx) ~= 'number' or type(g.ny) ~= 'number' or (g.hw ~= nil and type(g.hw) ~= 'number') then r.start = nil end
      if type(r.best) ~= 'table' or type(r.best.time) ~= 'number' then r.best = nil end
      if type(r.laps) ~= 'table' then r.laps = {} end
      if r.id ~= nil and type(r.id) ~= 'string' then r.id = tostring(r.id) end
      local ok = pcall(prepareRoute, r)
      if ok then routes[#routes + 1] = r end
    end
  end
  for _, r in ipairs(routes) do
    if r.repaired then
      log('I', logTag, string.format('route %s: repeated stretch removed, now %.0f m', tostring(r.id), r.len))
      r.repaired = nil
      saveRoutes()
    end
  end
end

local function nextId()
  local n = 0
  for _, r in ipairs(routes) do n = max(n, tonumber(tostring(r.id):match('^r(%d+)$')) or 0) end
  return 'r' .. (n + 1)
end

-- a route; added to the level's routes (and saved with its first lap) unless tentative
local function addRoute(pts, closed, source, start, finish, tentative)
  local r = prepareRoute({ closed = closed, source = source, created = os.date('%Y-%m-%d %H:%M'),
    pts = pts, start = start, finish = finish, tentative = tentative or nil })
  if not tentative then r.id = nextId() routes[#routes + 1] = r end
  return r
end

-- the route point nearest (x, y, z) in the hash, in the same direction
local function routeMatch(r, x, y, z, hx, hy, rad_)
  local best, bestD = nil, rad_ * rad_
  eachNear(r.cells, x, y, function(i)
    local p = r.pts[i]
    local dx, dy = p[1] - x, p[2] - y
    local d = dx * dx + dy * dy
    if d <= bestD and abs(p[3] - z) <= DZ_MAX and r.tx[i] * hx + r.ty[i] * hy >= HEAD_COS then best, bestD = i, d end
  end)
  return best
end

-- an existing route of the same kind that this one repeats
local function sameRoute(closed, len, x, y, z, hx, hy)
  for _, r in ipairs(routes) do
    if timed(r) and r.closed == closed and abs(r.len - len) <= 0.1 * len and routeMatch(r, x, y, z, hx, hy, MATCH_R) then return r end
  end
end

-- official courses ------------------------------------------------------------------

-- one course from the game's layout: its line, gates as wide as its checkpoints, and the
-- stations of its checkpoints (start and finish lines excluded)
local function courseRoute(c)
  if #c.cps < 2 then error('only ' .. #c.cps .. ' checkpoints found') end
  local pts, cpAt, approx = courseLib.buildLine(c)
  if #pts < 2 then error('no line') end
  local st = courseState[c.id] or {}
  local r = prepareRoute({ id = c.id, name = c.name, source = 'official', course = c.track, reverse = c.reverse or nil,
    closed = c.closed, pts = pts, created = st.created or os.date('%Y-%m-%d %H:%M'), enabled = st.enabled == true or nil,
    best = st.best, laps = type(st.laps) == 'table' and st.laps or {}, approx = approx or nil,
    missing = #c.missing > 0 and c.missing or nil })
  r.ccp = {}
  for k = 2, c.closed and #c.cps or #c.cps - 1 do
    if cpAt[k] and cpAt[k] > 1 then r.ccp[#r.ccp + 1] = r.s[cpAt[k]] end
  end
  r.start.hw = max(r.start.hw, min(c.cps[1].r or 0, 20))
  if r.finish then r.finish.hw = max(r.finish.hw, min(c.cps[#c.cps].r or 0, 20)) end
  -- a standing start on the spawn point: the line a little ahead, so pulling away crosses it
  if tostring(c.cps[1].name):match('_spawn$') then r.start.x, r.start.y = r.start.x + 3 * r.start.nx, r.start.y + 3 * r.start.ny end
  r.offTol = max(12, r.start.hw + 6)
  return r
end

-- marks the driver's routes (found before a course was turned on) that run along an enabled course
local function shadowRoutes()
  for _, r in ipairs(routes) do
    if r.source ~= 'official' then
      r.shadow = nil
      for _, c in ipairs(routes) do
        if c.source == 'official' and c.enabled and c.closed == r.closed and abs(c.len - r.len) <= 0.1 * c.len then
          local n, hit, tot = #r.pts, 0, 0
          for i = 1, n, max(1, floor(n / 20)) do
            tot = tot + 1
            if routeMatch(c, r.pts[i][1], r.pts[i][2], r.pts[i][3], r.tx[i], r.ty[i], c.offTol) then hit = hit + 1 end
          end
          if hit >= 0.9 * tot then r.shadow = c.id break end
        end
      end
      if r.shadow and active and active.route == r then active = nil end
    end
  end
end

-- the level's official courses, built once its road graph is there: one course a call (each
-- costs a few ms of path finding), or all that are left when all is set
local function buildCourses(all)
  if not (courseLib and level and level ~= '') then coursesLevel = level return end
  local q = courseQueue
  if not q or q.level ~= level then
    for i = #routes, 1, -1 do
      local r = routes[i]
      if r.source == 'official' then
        courseState[r.id] = { id = r.id, source = r.source, enabled = r.enabled, created = r.created, best = r.best, laps = r.laps }
        table.remove(routes, i)
      end
    end
    local t0 = os.clock()
    local ok, list = pcall(courseLib.list, level)
    if not ok then log('W', logTag, 'reading the quick race layouts failed: ' .. tostring(list)) list = {} end
    q = { level = level, list = list, i = 1, n = 0, ms = (os.clock() - t0) * 1000 }
    courseQueue = q
  end
  repeat
    local c = q.list[q.i]
    if not c then break end
    q.i = q.i + 1
    local t0 = os.clock()
    local okR, r = pcall(courseRoute, c)
    q.ms = q.ms + (os.clock() - t0) * 1000
    if okR then
      routes[#routes + 1] = r
      courseState[c.id] = nil
      q.n = q.n + 1
    else
      log('W', logTag, 'course ' .. tostring(c.id) .. ' skipped: ' .. tostring(r))
    end
  until not all
  if q.list[q.i] then return end
  courseQueue, coursesLevel, courseWait = nil, level, 0
  shadowRoutes()
  if q.n > 0 then log('I', logTag, string.format('%d official courses on %s (%.0f ms over several frames)', q.n, level, q.ms)) end
end

-- laps ------------------------------------------------------------------------------

local function newLap(r, t0, n)
  return { n = n, t0 = t0, valid = true, dist = 0, cpSeen = {}, cpCount = 0, ccSeen = {}, ccCount = 0, splits = {}, fi = 1,
    station = 0, prog = 0, offT = 0, offS = 0, lastTickT = t0 }
end

-- the ghost: the route's best lap (coDriverAnalysis keeps it as a file), loaded when a lap starts
local ghost = { route = nil, data = nil, k = 1, c = 1 }
-- best-lap files to make from the archive after a level loads (ensureBestEver), one per second
local bestFill = { queue = nil, wait = 0 }

local function startLap(r, t0, n)
  ghost.route = nil -- reload: a new best may have been kept since
  if M.getGuided and M.getGuided() == r.id then M.guideToStart(nil) end -- arrived: the markers go
  active = { route = r, lap = newLap(r, t0, n) }
  r.lastStartT = t0
  cand, p2pWatch = nil, nil
  return active.lap
end

-- a lap the driver sees (a loop still being confirmed is timed quietly)
local function shownLap() return active ~= nil and not active.route.tentative end

local function notifyAnalysis(info)
  if coDriverAnalysis and coDriverAnalysis.onLap then
    local ok, err = pcall(coDriverAnalysis.onLap, info)
    if not ok then log('W', logTag, 'analysis onLap failed: ' .. tostring(err)) end
  end
end

local function lapInfo(r, lap, t1, valid, reason, partial)
  return { route = r.id, name = r.name, closed = r.closed, len = round(r.len), n = lap.n, t0 = lap.t0, t1 = t1, time = round(t1 - lap.t0, 3),
    valid = valid, reason = reason, partial = partial or nil, progress = round(min(1, lap.prog / r.len), 2),
    checkpoints = r.ccp and { passed = lap.ccCount, total = #r.ccp } or nil,
    gate = { x = r.start.x, y = r.start.y, z = r.start.z, nx = r.start.nx, ny = r.start.ny } }
end

local function recordLap(r, info, splits)
  local prevBest = r.best and r.best.time
  info.best = info.valid and (not prevBest or info.time < prevBest) or false
  info.deltaBest = (info.valid and prevBest) and round(info.time - prevBest, 3) or nil
  if info.best then r.best = { time = info.time, splits = splits, date = os.date('%Y-%m-%d %H:%M') } end
  table.insert(r.laps, { date = os.date('%Y-%m-%d %H:%M'), n = info.n, time = info.time, valid = info.valid,
    reason = info.reason, partial = info.partial })
  while #r.laps > MAX_LAPS do table.remove(r.laps, 1) end
  saveRoutes()
  lastLap = { n = info.n, time = info.time, valid = info.valid, reason = info.reason, best = info.best,
    deltaBest = info.deltaBest, partial = info.partial, at = clock }
  notifyAnalysis(info)
  if coDriverEngineer and coDriverEngineer.onLap then pcall(coDriverEngineer.onLap, info) end
  log('I', logTag, string.format('lap %d on %s: %.3f s%s', info.n, r.id, info.time,
    info.valid and (info.best and ' (best)' or '') or (' invalid: ' .. tostring(info.reason))))
end

local function finishLap(t1)
  local r, lap = active.route, active.lap
  local cpOk = #r.cps == 0 or lap.cpCount / #r.cps >= 0.9
  local lenOk = abs(lap.dist - r.len) <= 0.15 * r.len
  local ccOk = not r.ccp or lap.ccCount >= #r.ccp -- an official course: every one of its checkpoints
  local valid = lap.valid and cpOk and lenOk and ccOk
  local reason = lap.reason or (not cpOk and 'missed checkpoints') or (not ccOk and 'missed a course checkpoint')
    or (not lenOk and 'distance does not match the route') or nil
  lap.prog = r.len
  active = nil
  if r.tentative then
    -- a found loop counts once it has been driven again: save it with both laps, or forget it
    if not cpOk then log('I', logTag, 'found loop not repeated; forgotten') return end
    r.tentative, r.id = nil, nextId()
    routes[#routes + 1] = r
    local p = r.pending
    r.pending = nil
    p.info.route = r.id
    local lap1 = p.info.time <= r.len / LAP1_MIN_V -- else the car stood still somewhere in it
    if lap1 then recordLap(r, p.info, p.splits) else lap.n = 1 end -- the confirming lap is then lap 1
    local info = lapInfo(r, lap, t1, valid, reason)
    recordLap(r, info, (valid and not lap.splitsBroken) and lap.splits or nil)
    notify(lap1 and string.format('Lap timing: found a %.1f km loop. Lap 1 %s, lap 2 %s.', r.len / 1000, M.fmtTime(p.info.time), M.fmtTime(info.time))
      or string.format('Lap timing: found a %.1f km loop. Lap 1 %s.', r.len / 1000, M.fmtTime(info.time)))
    return
  end
  recordLap(r, lapInfo(r, lap, t1, valid, reason), (valid and not lap.splitsBroken) and lap.splits or nil)
end

local function abandonLap(reason)
  if not active then return end
  local r, lap = active.route, active.lap
  if r.tentative then
    log('I', logTag, 'found loop not repeated (' .. reason .. '); forgotten')
  elseif lap.prog >= KEEP_PARTIAL * r.len then
    recordLap(r, lapInfo(r, lap, clock, false, reason, true), nil)
  else
    log('I', logTag, 'lap on ' .. r.id .. ' dropped: ' .. reason)
  end
  active = nil
end

-- checkpoints (stations in list) passed moving from station a by adv metres: marked in seen, counted
local function passCps(r, list, seen, a, adv)
  local n = 0
  for k, c in ipairs(list) do
    if not seen[k] then
      local rel = r.closed and (c - a) % r.len or (c - a)
      if rel > 0 and rel <= adv then seen[k], n = true, n + 1 end
    end
  end
  return n
end

-- progress along the route between ticks: checkpoints, splits (for the live delta), deviation
local function advance(r, lap, i)
  local a, b = lap.station, r.s[i]
  local adv = b - a
  if r.closed then
    if adv < -r.len / 2 then adv = adv + r.len elseif adv > r.len / 2 then adv = adv - r.len end
  end
  if adv > 0 and adv <= 120 then
    lap.cpCount = lap.cpCount + passCps(r, r.cps, lap.cpSeen, a, adv)
    if r.ccp then lap.ccCount = lap.ccCount + passCps(r, r.ccp, lap.ccSeen, a, adv) end
    local p0, p1 = lap.prog, lap.prog + adv
    local tPrev, tNow = lap.lastTickT - lap.t0, clock - lap.t0
    local k = #lap.splits + 1
    while not lap.splitsBroken and k * SPLIT_DS <= p1 do
      lap.splits[k] = round(tPrev + (tNow - tPrev) * max(0, (k * SPLIT_DS - p0) / adv), 3)
      k = k + 1
    end
    lap.prog = p1
  end
  lap.fi, lap.station = i, b
end

local function followRoute(dt, ds, x, y, z, hx, hy)
  local r, lap = active.route, active.lap
  local n = #r.pts
  local best, bestD = nil, math.huge
  for k = -3, 25 do
    local i = lap.fi + k
    if r.closed then i = (i - 1) % n + 1 elseif i < 1 or i > n then i = nil end
    if i then
      local p = r.pts[i]
      local d = (p[1] - x) ^ 2 + (p[2] - y) ^ 2
      if d < bestD and abs(p[3] - z) <= DZ_MAX + 2 then best, bestD = i, d end
    end
  end
  if best and bestD <= r.offTol * r.offTol then
    advance(r, lap, best)
    lap.offT, lap.offS = 0, 0
  else
    lap.offT, lap.offS = lap.offT + dt, lap.offS + ds
    if lap.valid and (lap.offT > OFF_T or lap.offS > OFF_S) then
      lap.valid, lap.reason = false, 'left the route'
    end
    if lap.offT > ABANDON_T or lap.offS > ABANDON_S then abandonLap('left the route') return end
    -- back on the route somewhere else (a shortcut or a detour): carry on, without the skipped checkpoints
    local j = routeMatch(r, x, y, z, hx, hy, MATCH_R)
    if j then
      lap.fi, lap.station, lap.offT, lap.offS = j, r.s[j], 0, 0
      lap.prog = r.closed and max(lap.prog, (r.s[j] - r.s[1]) % r.len) or r.s[j]
      lap.splitsBroken = true
    end
  end
  lap.lastTickT = clock
end

local function liveDelta(r, lap)
  local b = r.best
  if not (b and type(b.splits) == 'table' and lap.valid and not lap.splitsBroken) then return nil end
  local k = #lap.splits
  if k < 1 or not b.splits[k] then return nil end
  return round(lap.splits[k] - b.splits[k], 2)
end

-- gates ---------------------------------------------------------------------------

-- fraction (0..1] of the move a -> b where it crosses the gate forwards inside its width, or nil
local function crossGate(g, ax, ay, az, bx, by, bz)
  local da = (ax - g.x) * g.nx + (ay - g.y) * g.ny
  local db = (bx - g.x) * g.nx + (by - g.y) * g.ny
  if not (da <= 0 and db > 0) then return nil end
  local f = -da / (db - da)
  local cx, cy, cz = ax + (bx - ax) * f, ay + (by - ay) * f, az + (bz - az) * f
  local lat = (cx - g.x) * -g.ny + (cy - g.y) * g.nx
  if abs(lat) > g.hw or abs(cz - g.z) > DZ_MAX then return nil end
  return f
end

-- the time the trail crossed gate g between crumbs i1 and i2, interpolated
local function trailCrossing(g, i1, i2)
  local tr = trail
  for i = max(i1, 2), min(i2, tr.n) do
    if tr.seg[i] == tr.seg[i - 1] then
      local f = crossGate(g, tr.x[i - 1], tr.y[i - 1], tr.z[i - 1], tr.x[i], tr.y[i], tr.z[i])
      if f then return tr.t[i - 1] + (tr.t[i] - tr.t[i - 1]) * f, tr.s[i - 1] + (tr.s[i] - tr.s[i - 1]) * f, i end
    end
  end
end

-- a lap that started at (t0, s0) on the trail, continued up to now: progress, checkpoints and splits so far
local function catchUp(r, lap, iFrom, s0)
  local tr = trail
  local sNow = tr.s[tr.n]
  lap.dist = sNow - s0
  lap.splits = trailSplits(iFrom, tr.n, lap.t0, s0)
  lap.prog = sNow - s0
  local hx, hy = tr.hx[tr.n], tr.hy[tr.n]
  local j = routeMatch(r, tr.x[tr.n], tr.y[tr.n], tr.z[tr.n], hx, hy, r.offTol)
  if j then lap.fi, lap.station = j, r.s[j] end
  for k, c in ipairs(r.cps) do
    if c <= lap.prog then lap.cpSeen[k], lap.cpCount = true, lap.cpCount + 1 end
  end
  lap.lastTickT = clock
end

local function makeLoop(c)
  local tr = trail
  local g = gateAt({ tr.x[c.j0], tr.y[c.j0], tr.z[c.j0] }, tr.hx[c.j0], tr.hy[c.j0])
  local t1, s1, iCross = trailCrossing(g, c.i0 - 5, tr.n)
  if not t1 then log('W', logTag, 'loop found but the gate crossing was not') return end
  local len = s1 - tr.s[c.j0]
  if len < MIN_LOOP_S then return end
  local known = sameRoute(true, len, tr.x[c.j0], tr.y[c.j0], tr.z[c.j0], tr.hx[c.j0], tr.hy[c.j0])
  if known then return end -- a saved route: laps start at its own gate
  local pts = {}
  for i = c.j0, iCross - 1 do pts[#pts + 1] = { tr.x[i], tr.y[i], tr.z[i] } end
  -- tentative until lap 2 repeats it (finishLap), so driving down a street twice makes no route
  local r = addRoute(pts, true, 'auto', g, nil, true)
  local lap1 = newLap(r, tr.t[c.j0], 1)
  lap1.prog = r.len
  local valid = not resetBetween(lap1.t0, t1)
  r.pending = { info = lapInfo(r, lap1, t1, valid, not valid and 'car reset' or nil),
    splits = valid and trailSplits(c.j0, iCross, lap1.t0, tr.s[c.j0]) or nil }
  log('I', logTag, string.format('possible %.0f m loop; timing lap 2 to confirm it', r.len))
  catchUp(r, startLap(r, t1, 2), iCross - 1, s1)
end

local function makeP2P(c)
  local tr = trail
  local pts = {}
  for i = c.j0, c.jEnd do pts[#pts + 1] = { tr.x[i], tr.y[i], tr.z[i] } end
  if #pts < 2 or tr.s[c.jEnd] - tr.s[c.j0] < MIN_LOOP_S then return end
  local r = sameRoute(false, tr.s[c.jEnd] - tr.s[c.j0], tr.x[c.j0], tr.y[c.j0], tr.z[c.j0], tr.hx[c.j0], tr.hy[c.j0])
  local found = r == nil
  r = r or addRoute(pts, false, 'auto')
  if found then
    saveRoutes()
    notify(string.format('Lap timing: found a %.1f km point-to-point run.', r.len / 1000))
  end
  -- this run: timed from where it crossed the start line, if it did
  local first = tr.segStart[seg]
  local t0, s0, iCross = trailCrossing(r.start, first, tr.n)
  if t0 then
    catchUp(r, startLap(r, t0, 1), iCross - 1, s0)
  else
    -- placed just past the line (within 5 m) still counts; further on, the time would be short
    local g = r.start
    local past = (tr.x[first] - g.x) * g.nx + (tr.y[first] - g.y) * g.ny
    local lap = startLap(r, tr.t[first], 1)
    catchUp(r, lap, first, tr.s[first])
    if past > 5 then lap.valid, lap.reason = false, 'started past the start line' end
  end
end

-- matching: returning to the trail, or repeating an earlier run ------------------------------

-- The trail point to rejoin: on the most recent earlier pass here (an older pass would make
-- lap 1 everything driven since then), the nearest point of that pass.
local function findReturn(x, y, z, hx, hy)
  local tr = trail
  local sNow, short, found, jMax = tr.s[tr.n], false, {}, nil
  eachNear(tr.cells, x, y, function(j)
    if tr.seg[j] == seg then
      local age = sNow - tr.s[j]
      if age >= SHORT_LOOP_S then
        local d = crumbMatch(j, x, y, z, hx, hy, MATCH_R)
        if d then
          if age < MIN_LOOP_S then short = true
          elseif clock - tr.t[j] >= MIN_LOOP_T then
            found[#found + 1] = { j, d }
            jMax = max(jMax or j, j)
          end
        end
      end
    end
  end)
  if short or not jMax then return nil end
  local best, bestD = nil, math.huge
  for _, e in ipairs(found) do
    if e[1] >= jMax - 6 and e[2] < bestD then best, bestD = e[1], e[2] end
  end
  return best
end

local function followTrail(c, x, y, z, hx, hy)
  local best, bestD = nil, math.huge
  for j = c.j, min(c.j + 15, c.jEnd or trail.n) do
    local d = crumbMatch(j, x, y, z, hx, hy, FOLLOW_R)
    if d and d < bestD then best, bestD = j, d end
  end
  return best
end

local function discover(x, y, z, hx, hy)
  local tr = trail
  if tr.n == 0 then return end
  if cand then
    local j = followTrail(cand, x, y, z, hx, hy)
    if j then
      cand.j, cand.miss, cand.matched = j, 0, true
    elseif cand.matched or tr.s[tr.n] - cand.s0 > 60 then
      cand.miss = cand.miss + 1
    end
    if cand.miss > 4 then cand = nil return end
    local need = cand.kind == 'p2p' and P2P_CONFIRM_S or CONFIRM_S
    if cand.matched and tr.s[tr.n] - cand.s0 >= need then
      local c = cand
      cand = nil
      if c.kind == 'loop' then makeLoop(c) else makeP2P(c) end
    end
    return
  end
  -- a new stretch after a teleport: does it start where an earlier run started?
  if p2pWatch and tr.segStart[seg] then
    p2pWatch = nil
    local f = tr.segStart[seg]
    for sid = seg - 1, 1, -1 do
      local j0, j1 = tr.segStart[sid], tr.segEnd[sid]
      if j0 and j1 and tr.s[j1] - tr.s[j0] >= MIN_LOOP_S and crumbMatch(j0, tr.x[f], tr.y[f], tr.z[f], tr.hx[f], tr.hy[f], P2P_START_R) then
        cand = { kind = 'p2p', j0 = j0, j = j0, jEnd = j1, i0 = tr.n, s0 = tr.s[f], miss = 0 }
        return
      end
    end
  end
  local j = findReturn(x, y, z, hx, hy)
  if j then cand = { kind = 'loop', j0 = j, j = j, i0 = tr.n, s0 = tr.s[tr.n], miss = 0, matched = true } end
end

-- manual marks --------------------------------------------------------------------

local function markGate()
  if not (lastPos and lastHx) then return nil end
  return gateAt({ lastPos.x, lastPos.y, lastPos.z }, lastHx, lastHy)
end

-- a manual start mark crossed again after a lap's worth of driving: a loop
local function closeMarkedLoop(t1)
  local tr = trail
  local pts = { { marks.g.x, marks.g.y, marks.g.z } }
  for i = marks.i + 1, tr.n do pts[#pts + 1] = { tr.x[i], tr.y[i], tr.z[i] } end
  local r = addRoute(pts, true, 'manual', marks.g)
  local lap1 = newLap(r, marks.t, 1)
  lap1.prog = r.len
  local valid = not resetBetween(marks.t, t1)
  recordLap(r, lapInfo(r, lap1, t1, valid, not valid and 'car reset' or nil), nil)
  notify(string.format('Lap timing: %.1f km loop saved. Lap 1 was %s.', r.len / 1000, M.fmtTime(t1 - marks.t)))
  marks = nil
  startLap(r, t1, 2)
end

-- per frame -------------------------------------------------------------------------

local function newSegment()
  seg = seg + 1
  cand = nil
  marks = nil
  p2pWatch = { seg = seg }
end

local function checkGates(lp, x, y, z, t0, dt)
  if active then
    local r, lap = active.route, active.lap
    local g = r.closed and r.start or r.finish
    if clock - lap.t0 > DEBOUNCE and lap.dist >= 0.5 * r.len then
      local f = crossGate(g, lp.x, lp.y, lp.z, x, y, z)
      if f then
        local t1 = t0 + dt * f
        finishLap(t1)
        if r.closed and not r.tentative then startLap(r, t1, lap.n + 1) end -- (finishLap can renumber it)
      end
    end
    return
  end
  if marks and marks.seg == seg and trail.n > 0 and trail.s[trail.n] - marks.s >= MIN_LOOP_S / 2 then
    local f = crossGate(marks.g, lp.x, lp.y, lp.z, x, y, z)
    if f then closeMarkedLoop(t0 + dt * f) return end
  end
  for _, r in ipairs(routes) do
    local g = r.start
    if timed(r) and abs(x - g.x) < 60 and abs(y - g.y) < 60 and clock - (r.lastStartT or -1e9) > DEBOUNCE then
      local f = crossGate(g, lp.x, lp.y, lp.z, x, y, z)
      -- only while following the route there: a side street across the line (or a start line on a
      -- corner, whose gate faces diagonally) is told apart by the route's own direction near the car
      if f and lastHx and routeMatch(r, x, y, z, lastHx, lastHy, r.offTol) then startLap(r, t0 + dt * f, 1) cand = nil return end
    end
  end
end

-- one frame: dt in simulation seconds, position and velocity, and the car's forward direction
local lastSp = 0
local function step(dt, x, y, z, vx, vy, vz, fx, fy)
  if not dt or dt <= 0 then return end
  if not trail then trail = newTrail() end
  local t0 = clock
  clock = clock + dt
  local sp = sqrt(vx * vx + vy * vy)
  local hx, hy
  if sp > 1 then
    hx, hy = vx / sp, vy / sp
  elseif fx and (fx ~= 0 or fy ~= 0) then
    local l = sqrt(fx * fx + fy * fy)
    hx, hy = fx / l, fy / l
  end
  lastHx, lastHy = hx or lastHx, hy or lastHy
  local lp, ds = lastPos, 0
  if lp then
    local dx, dy, dz = x - lp.x, y - lp.y, z - lp.z
    local jump = sqrt(dx * dx + dy * dy + dz * dz)
    -- the frame after a teleport reports a huge velocity and a reset can come with a long frame,
    -- so the allowance uses the speed before this frame and a capped frame time
    if jump > max(TELEPORT_M, min(lastSp, 120) * min(dt, 0.25) * 2) then
      newSegment()
      if active then abandonLap('car moved (reset or teleport)') end
    else
      ds = sqrt(dx * dx + dy * dy)
      if active then active.lap.dist = active.lap.dist + ds end
      checkGates(lp, x, y, z, t0, dt)
    end
  else
    newSegment()
  end
  lastPos = lastPos or {}
  lastPos.x, lastPos.y, lastPos.z = x, y, z
  lastSp = sp
  if hx and sp > 1 then dropCrumb(x, y, z, hx, hy) end
  tickAcc = tickAcc + dt
  tickDs = tickDs + ds
  if tickAcc >= TICK then
    -- a lap is followed even while parked (off the route, its time runs out); finding routes needs motion
    local fhx, fhy = hx or lastHx, hy or lastHy
    if active and fhx then followRoute(tickAcc, tickDs, x, y, z, fhx, fhy) end
    if not active and hx and sp > 1 and cfg.discovery ~= 'off' then discover(x, y, z, hx, hy) end
    tickAcc, tickDs = 0, 0
  end
end

local function sendUi(dt)
  uiAcc = uiAcc + dt
  if uiAcc < 0.2 then return end
  uiAcc = 0
  local showLast = lastLap and clock - lastLap.at < 8
  if not shownLap() and not showLast then
    if uiWasActive then guihooks.trigger('CoDriverLaps', { active = false }) uiWasActive = false end
    return
  end
  uiWasActive = true
  local d = { active = shownLap(), last = showLast and lastLap or nil, lastAge = showLast and round(clock - lastLap.at, 1) or nil }
  if shownLap() then
    local r, lap = active.route, active.lap
    d.n, d.time, d.valid, d.reason = lap.n, clock - lap.t0, lap.valid, lap.reason
    d.best, d.delta, d.closed, d.len = r.best and r.best.time, liveDelta(r, lap), r.closed, round(r.len)
    d.progress = round(min(1, lap.prog / r.len), 3)
    -- a sector (third of the lap) just finished: its own gap to the best lap's same sector
    local k = min(2, floor(lap.prog / r.len * 3))
    if k > (lap.secK or 0) then
      lap.secK = k
      if d.delta then
        lap.secD = round(d.delta - (lap.secCum or 0), 2)
        lap.secCum, lap.secAt = d.delta, clock
      end
    end
    if lap.secAt and clock - lap.secAt < 6 then d.sector = { k = lap.secK, delta = lap.secD } end
  end
  guihooks.trigger('CoDriverLaps', d)
end

local function coachEnabled()
  if not coDriverCoach or not coDriverCoach.isEnabled then return true end
  return coDriverCoach.isEnabled()
end

local function replayPlaying()
  return core_replay and core_replay.getState and core_replay.getState() == 'playback'
end

local function onUpdate(dtReal, dtSim)
  local lvl = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  if lvl ~= level then
    if active then abandonLap('level changed') end
    level, trail, lastPos = lvl, newTrail(), nil
    loadRoutes()
    bestFill.queue, bestFill.wait = nil, 3
  end
  if lvl and bestFill.wait > 0 then
    bestFill.wait = bestFill.wait - (dtReal or 0)
    if bestFill.wait <= 0 then
      if not bestFill.queue then -- routes with a best whose lap isn't kept yet
        bestFill.queue = {}
        for _, r in ipairs(routes) do
          if r.best and r.best.time and not r.tentative then bestFill.queue[#bestFill.queue + 1] = { id = r.id, time = r.best.time } end
        end
      end
      local job = table.remove(bestFill.queue, 1)
      if job and coDriverAnalysis and coDriverAnalysis.ensureBestEver then
        local ok, err = pcall(coDriverAnalysis.ensureBestEver, lvl, job.id, job.time)
        if not ok then log('W', logTag, 'best lap backfill failed: ' .. tostring(err)) end
      end
      if #bestFill.queue > 0 then bestFill.wait = 1 end
    end
  end
  if lvl and coursesLevel ~= lvl then
    local okM, nodes = pcall(function() return map.getMap().nodes end)
    courseWait = courseWait + 1
    if (okM and type(nodes) == 'table' and next(nodes)) or courseWait > 600 then buildCourses(false) end
  end
  if not lvl or replayPlaying() then lastPos = nil return end
  local veh = getPlayerVehicle(0)
  if not veh or not coachEnabled() then
    if active then abandonLap('coach off or no car') end
    lastPos = nil
    return
  end
  if veh:getId() ~= vehId then
    if active then abandonLap('car switched') end
    vehId, lastPos = veh:getId(), nil
  end
  local p, v, f = veh:getPosition(), veh:getVelocity(), veh:getDirectionVector()
  step(dtSim, p.x, p.y, p.z, v.x, v.y, v.z, f.x, f.y)
  sendUi(dtSim)
end

local function onVehicleResetted(id)
  if id ~= vehId then return end
  resets[#resets + 1] = clock
  while #resets > 50 do table.remove(resets, 1) end
  cand = nil
  if active and active.lap.valid then active.lap.valid, active.lap.reason = false, 'car reset' end
end

-- public ------------------------------------------------------------------------------

M.fmtTime = function(t)
  t = max(0, t or 0)
  local m = floor(t / 60)
  return string.format('%d:%06.3f', m, t - m * 60)
end

-- For the race engineer: the lap under way, the last lap and this route's recent laps (times as
-- m:ss.sss text, gaps in seconds; nil when there are no laps).
-- where the timed lap is, for recce pacenotes: nil unless a lap of a known route is running
M.getProgress = function()
  if not active or active.route.tentative then return nil end
  local r = active.route
  return { level = level, route = r.id, n = active.lap.n, prog = active.lap.prog, len = r.len, closed = r.closed or false }
end

M.radioState = function()
  local out = {}
  local function short(t) return t and M.fmtTime(t):sub(1, -2) or nil end -- 1:02.27
  if active and not active.route.tentative then
    local r, lap = active.route, active.lap
    out.current = { lap = lap.n, time = short(clock - lap.t0), valid = lap.valid, notCountedBecause = lap.reason,
      gapToBestNow = liveDelta(r, lap), donePct = floor(min(1, lap.prog / r.len) * 100) }
    out.route = { km = round(r.len / 1000, 2), kind = r.closed and 'loop' or 'point to point', bestEver = r.best and short(r.best.time),
      name = r.name, officialCourse = r.source == 'official' or nil }
    local recent = {}
    for i = max(1, #r.laps - 4), #r.laps do
      local l = r.laps[i]
      recent[#recent + 1] = { lap = l.n, time = short(l.time), valid = l.valid, date = l.date }
    end
    out.recentLaps = recent
  end
  if lastLap then
    out.lastLap = { lap = lastLap.n, time = short(lastLap.time), valid = lastLap.valid, notCountedBecause = lastLap.reason,
      gapToBest = lastLap.deltaBest, newBest = lastLap.best or nil, secondsAgo = floor(clock - lastLap.at) }
  end
  return next(out) and out or nil
end

-- The ghost at lap time t on the route's best lap: x, y, z and the point index (nil past its end).
local function ghostAt(d, t)
  local p = d.pts
  local k = ghost.k
  if not p.t[k] or p.t[k] > t then k = 1 end
  while p.t[k + 1] and p.t[k + 1] <= t do k = k + 1 end
  ghost.k = k
  if not p.t[k + 1] then return nil end
  local f = (t - p.t[k]) / max(1e-3, p.t[k + 1] - p.t[k])
  return p.x[k] + (p.x[k + 1] - p.x[k]) * f, p.y[k] + (p.y[k + 1] - p.y[k]) * f, p.z[k] + (p.z[k + 1] - p.z[k]) * f, k
end

local function ghostData(r)
  if ghost.route ~= r.id then
    ghost.route, ghost.k, ghost.c, ghost.data = r.id, 1, 1, nil
    if coDriverAnalysis and coDriverAnalysis.loadBestEver then
      local ok, d = pcall(coDriverAnalysis.loadBestEver, level, r.id)
      ghost.data = ok and d or nil
    end
  end
  return ghost.data
end

-- drawn every frame during a lap when the ghost is on: a marker where the best lap was at this lap
-- time, and with 'line' the best lap's line for the next 200 m ahead of the car (a few prisms)
M.onPreRender = function()
  if (cfg.ghost ~= 'marker' and cfg.ghost ~= 'line') or not shownLap() or replayPlaying() then return end
  local r, lap = active.route, active.lap
  local d = ghostData(r)
  if not d then return end
  local x, y, z = ghostAt(d, clock - lap.t0)
  if x then debugDrawer:drawSphere(vec3(x, y, z + 0.8), 0.55, ColorF(0.35, 0.72, 1, 0.85)) end
  if cfg.ghost == 'line' and lastPos then
    local p = d.pts
    local c, bd = ghost.c, math.huge
    for i = max(1, ghost.c - 5), min(#p.x, ghost.c + 40) do
      local dd = (p.x[i] - lastPos.x) ^ 2 + (p.y[i] - lastPos.y) ^ 2
      if dd < bd then c, bd = i, dd end
    end
    if bd > 30 * 30 then -- lost it (a reset): search the whole lap
      for i = 1, #p.x do
        local dd = (p.x[i] - lastPos.x) ^ 2 + (p.y[i] - lastPos.y) ^ 2
        if dd < bd then c, bd = i, dd end
      end
    end
    ghost.c = c
    local w, col = Point2F(0.03, 0.35), ColorF(0.35, 0.72, 1, 0.5)
    for i = c, min(#p.x - 1, c + 50) do
      debugDrawer:drawSquarePrism(vec3(p.x[i], p.y[i], p.z[i] + 0.06), vec3(p.x[i + 1], p.y[i + 1], p.z[i + 1] + 0.06), w, w, col)
    end
  end
end
-- a new best lap was kept (coDriverAnalysis): the ghost reloads it now rather than next lap
M.bestChanged = function(id) if ghost.route == id then ghost.route = nil end end
M._ghostAt = function(t) local d = active and ghostData(active.route) if d then return ghostAt(d, t) end end

M.onExtensionLoaded = loadSettings
M.onUpdate = onUpdate
M.onVehicleResetted = onVehicleResetted
M.onClientEndMission = function()
  if active then abandonLap('level ended') end
  level, trail, lastPos, routes, courseState, coursesLevel, courseQueue = nil, nil, nil, {}, {}, nil, nil
end

M.step = step
M.getClock = function() return clock end
M.isLapActive = function() return shownLap() and true or false end

-- whether a replay should be recording: a lap in progress, or heading for a start line close by
-- For the 'laps' replay mode: a lap under way (a found loop's confirming lap too, so it has a
-- replay once confirmed), anywhere on a saved route in its direction (an out-lap that joins part
-- way round), or heading for a start line.
M.wantsReplay = function()
  if active then return true end
  if not (lastPos and lastHx) then return false end
  for _, r in ipairs(routes) do
    if timed(r) then
      if routeMatch(r, lastPos.x, lastPos.y, lastPos.z, lastHx, lastHy, r.offTol or 12) then return true end
      local g = r.start
      local dx, dy = g.x - lastPos.x, g.y - lastPos.y
      if dx * dx + dy * dy < 150 * 150 and dx * g.nx + dy * g.ny > 0 and lastHx * g.nx + lastHy * g.ny > 0.5 then return true end
    end
  end
  return false
end

M.markStart = function()
  local g = markGate()
  if not g then return false end
  if active then abandonLap('new start marked') end
  marks = { g = g, seg = seg, i = trail.n, s = trail.n > 0 and trail.s[trail.n] or 0, t = clock }
  notify('Lap timing: start marked. Drive to the finish and mark it, or come back here for a loop.')
  return true
end

M.markFinish = function()
  local g = markGate()
  if not (g and marks and marks.seg == seg and trail.n > marks.i) then
    notify('Lap timing: mark a start first.')
    return false
  end
  local tr = trail
  if tr.s[tr.n] - marks.s < 100 then notify('Lap timing: the finish must be at least 100 m from the start.') return false end
  local pts = { { marks.g.x, marks.g.y, marks.g.z } }
  for i = marks.i + 1, tr.n do pts[#pts + 1] = { tr.x[i], tr.y[i], tr.z[i] } end
  pts[#pts + 1] = { g.x, g.y, g.z }
  local r = addRoute(pts, false, 'manual', marks.g, g)
  local lap1 = newLap(r, marks.t, 1)
  lap1.prog = r.len
  local valid = not resetBetween(marks.t, clock)
  recordLap(r, lapInfo(r, lap1, clock, valid, not valid and 'car reset' or nil), nil)
  notify(string.format('Lap timing: %.1f km run saved. That run was %s.', r.len / 1000, M.fmtTime(clock - marks.t)))
  marks = nil
  return true
end

-- a route's best-lap file (and with recce, its recce notes): a deleted route's id is given out again
local function forgetFiles(id, recce)
  local p = coDriverAnalysis and coDriverAnalysis.bestEverPath and coDriverAnalysis.bestEverPath(level, id)
  if p and FS:fileExists(p) then FS:removeFile(p) end
  if recce and coDriverCoach and coDriverCoach.recceClear then pcall(coDriverCoach.recceClear, level, id) end
  if ghost.route == id then ghost.route = nil end
end

-- deletes the route being timed, or else the one whose line is nearest (within 100 m); official
-- courses can't be deleted (setCourseEnabled turns them off)
M.clearRoute = function(id)
  local target
  if id then
    for _, r in ipairs(routes) do if r.id == id then target = r end end
  elseif shownLap() then
    target = active.route
  end
  if not target and lastPos then
    local bestD = 100 * 100
    for _, r in ipairs(routes) do
      local d = (r.start.x - lastPos.x) ^ 2 + (r.start.y - lastPos.y) ^ 2
      if d < bestD and r.source ~= 'official' then target, bestD = r, d end
    end
  end
  if target and target.source == 'official' then
    notify('Lap timing: ' .. tostring(target.name) .. ' is an official course; turn it off instead.')
    return false
  end
  if not target then notify('Lap timing: no route here to delete.') return false end
  if active and active.route == target then active = nil end
  for i, r in ipairs(routes) do if r == target then table.remove(routes, i) break end end
  saveRoutes()
  pcall(forgetFiles, target.id, true)
  notify(string.format('Lap timing: deleted the %.1f km route.', target.len / 1000))
  return true
end

M.setOption = function(k, v)
  if defaults[k] == nil then return false end
  if k == 'discovery' and v ~= 'auto' and v ~= 'off' then return false end
  if k == 'ghost' and v ~= 'off' and v ~= 'marker' and v ~= 'line' then return false end
  cfg[k] = v
  if not FS:directoryExists('settings/coDriverCoach') then FS:directoryCreate('settings/coDriverCoach', true) end
  jsonWriteFile(SETTINGS, cfg, true)
  return true
end

-- forgets a route's laps and best lap, keeping the route (the current one, or by id)
M.clearLaps = function(id)
  local target = not id and shownLap() and active.route or nil
  for _, r in ipairs(routes) do if r.id == id then target = r end end
  if not target then return false end
  target.laps, target.best = {}, nil
  saveRoutes()
  pcall(forgetFiles, target.id, false)
  return true
end

M.getOptions = function() return { discovery = cfg.discovery, ghost = cfg.ghost, level = level } end

-- the driver's own routes (found and marked); official courses are in getCourses()
M.getRoutes = function()
  local out = {}
  for _, r in ipairs(routes) do
    if r.source ~= 'official' then
      out[#out + 1] = { id = r.id, closed = r.closed, len = round(r.len), source = r.source, best = r.best and r.best.time,
        laps = #r.laps, created = r.created, course = r.shadow, away = M._away(r) }
    end
  end
  return out
end

-- the level's official courses: id, name, length (m), closed, enabled, best (s), laps, checkpoints;
-- approx when part of the line is straight (no road between two checkpoints)
M.getCourses = function()
  if level and coursesLevel ~= level then buildCourses(true) end
  local out = {}
  for _, r in ipairs(routes) do
    if r.source == 'official' then
      out[#out + 1] = { id = r.id, name = r.name, track = r.course, reverse = r.reverse == true, length = round(r.len, 0),
        closed = r.closed, enabled = r.enabled == true, best = r.best and r.best.time, laps = #r.laps,
        checkpoints = #r.ccp, approx = r.approx, missing = r.missing, away = M._away(r) }
    end
  end
  return out
end

-- times laps on an official course (on = true) or stops (false); kept in the level's routes file
M.setCourseEnabled = function(id, on)
  if level and coursesLevel ~= level then buildCourses(true) end
  on = on == true or on == 1 or on == 'on'
  for _, r in ipairs(routes) do
    if r.source == 'official' and r.id == id then
      r.enabled = on or nil
      if not on and active and active.route == r then active = nil end
      shadowRoutes()
      saveRoutes()
      notify(string.format('Lap timing: %s %s.', tostring(r.name), on and 'is timed now' or 'is not timed any more'))
      return true
    end
  end
  return false
end

M.getState = function()
  local a = active and { route = active.route.id, n = active.lap.n, time = clock - active.lap.t0, valid = active.lap.valid,
    reason = active.lap.reason, prog = active.lap.prog, cps = active.lap.cpCount, dist = active.lap.dist,
    sector = active.lap.secK, sectorGap = active.lap.secD } or nil
  if a then a.name, a.coursePassed, a.courseTotal = active.route.name, active.lap.ccCount, active.route.ccp and #active.route.ccp end
  local nc, on = 0, {}
  for _, r in ipairs(routes) do
    if r.source == 'official' then nc = nc + 1 if r.enabled then on[#on + 1] = r.id end end
  end
  return { level = level, clock = clock, crumbs = trail and trail.n or 0, seg = seg, cand = cand and cand.kind,
    active = a, routes = M.getRoutes(), courses = nc, coursesOn = on, lastLap = lastLap, discovery = cfg.discovery }
end

-- tests: forget everything in memory (files stay), as if the game had just started on this level
M._reset = function(lvl)
  clock, seg, cand, p2pWatch, marks, active, lastPos, lastHx, lastHy = 0, 0, nil, nil, nil, nil, nil, nil, nil
  resets, lastLap, tickAcc, uiAcc, uiWasActive = {}, nil, 0, 0, false
  trail, level = newTrail(), lvl
  loadSettings()
  loadRoutes()
  buildCourses(true)
end
M._routes = function() return routes end

-- Getting to a route's start line ------------------------------------------------------
-- guideToStart: the game's ground markers lead to the start (cleared on arrival, when that route's
-- lap starts, or by calling it again with nil); takeToStart: the car is put about 40 m before the
-- line, facing it (on a loop, on its last stretch; on a point-to-point route, on the line through its
-- first metres, extended backwards; spawn.safeTeleport moves it to the nearest safe spot).
local guided = nil -- the route id the markers lead to

local function routeById(id)
  for _, r in ipairs(routes) do if r.id == id then return r end end
end

-- metres from the car to a route's start, in a straight line (nil when the car isn't known)
M._away = function(r)
  if not (lastPos and r and r.start) then return nil end
  return round(sqrt((r.start.x - lastPos.x) ^ 2 + (r.start.y - lastPos.y) ^ 2), 0)
end

M.guideToStart = function(id)
  if not (core_groundMarkers and core_groundMarkers.setPath) then return false end
  local r = id and routeById(id)
  if not r or not r.start then
    core_groundMarkers.setPath(nil)
    guided = nil
    return false
  end
  core_groundMarkers.setPath(vec3(r.start.x, r.start.y, r.start.z), { clearPathOnReachingTarget = true })
  guided = r.id
  notify(string.format('Lap timing: follow the markers to the start of %s (%.1f km away).', tostring(r.name or r.id), (M._away(r) or 0) / 1000))
  return true
end

M.getGuided = function() return guided end

-- the place about `back` metres before the start along the route, and the heading there
local function beforeStart(r, back)
  local p, n = r.pts, #r.pts
  if r.closed then
    local acc, i = 0, n
    while i > 1 and acc < back do
      local a, b = p[i], p[i % n + 1]
      acc = acc + sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
      i = i - 1
    end
    local a, b = p[i], p[i % n + 1]
    return vec3(a[1], a[2], a[3]), vec3(b[1] - a[1], b[2] - a[2], 0)
  end
  -- point to point: the start is the route's first point, and the car must cross the line, so it
  -- goes the same distance before it, along the direction of the first stretch
  local a, b = p[1], p[min(n, 4)]
  local dir = vec3(b[1] - a[1], b[2] - a[2], 0)
  dir = dir:length() > 0.1 and dir:normalized() or vec3(r.start.nx, r.start.ny, 0)
  return vec3(a[1], a[2], a[3]) - dir * back, dir
end

M.takeToStart = function(id)
  local r = id and routeById(id)
  local veh = getPlayerVehicle(0)
  if not r or not veh or not r.pts or #r.pts < 2 then return false end
  if active then abandonLap('moved to a start line') end
  local pos, dir = beforeStart(r, 40)
  if dir:length() < 0.01 then dir = vec3(r.start.nx, r.start.ny, 0) end
  local rot = quatFromDir(dir:normalized(), vec3(0, 0, 1))
  if spawn and spawn.safeTeleport then
    spawn.safeTeleport(veh, pos, rot, nil, nil, nil, nil, true)
  else
    veh:setPosRot(pos.x, pos.y, pos.z + 0.5, rot.x, rot.y, rot.z, rot.w)
  end
  if guided then M.guideToStart(nil) end
  notify(string.format('Lap timing: %s starts just ahead.', tostring(r.name or r.id)))
  return true
end

return M
