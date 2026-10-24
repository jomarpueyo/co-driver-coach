-- Co-Driver Coach: the level's official quick race layouts, read as lap routes (docs/PLAN_FROM_RESEARCH.md Phase C).
-- Two formats live in levels/<level>/quickrace/:
-- * <track>.json: name (a translation key), closed, reversible, lapConfig (checkpoint names),
--   finishLineCheckpoint, startLineCheckpoint. The checkpoints are BeamNGWaypoint objects in the
--   Torque prefabs <track>.prefab plus <track>_forward.prefab or <track>_reverse.prefab (the
--   direction's copy wins, as in the game, where it is spawned last).
-- * <track>.race.json (newer): pathnodes (pos, radius) joined by segments from startNode, with
--   classification.closed / reversible. Branching layouts are skipped.
-- The game's own order (scenario/quickRaceLoader.lua, gameplay/race/path.lua): a closed course runs
-- finish line, lapConfig..., finish line; reversed, lapConfig is reversed (and an open course swaps
-- its start and finish). The line follows the road graph from checkpoint to checkpoint.
local M = {}
local sqrt, max, min, floor = math.sqrt, math.max, math.min, math.floor
local logTag = 'coDriverLaps'
local STEP = 4 -- line point spacing (m)

local function readText(f)
  if not FS:fileExists(f) then return nil end
  local ok, txt = pcall(readFile, f)
  return ok and txt or nil
end

-- named BeamNGWaypoint objects of a Torque prefab file into out: name -> { x, y, z, r }
local function prefabWaypoints(file, out)
  local txt = readText(file)
  if not txt then return false end
  local function add(name, body)
    local x, y, z = body:match('position%s*=%s*"%s*([%-%d%.eE]+)%s+([%-%d%.eE]+)%s+([%-%d%.eE]+)"')
    if not x then return end
    local sx, sy, sz = body:match('scale%s*=%s*"%s*([%-%d%.eE]+)%s+([%-%d%.eE]+)%s+([%-%d%.eE]+)"')
    out[name] = { x = tonumber(x), y = tonumber(y), z = tonumber(z),
      r = sx and max(tonumber(sx), tonumber(sy), tonumber(sz)) or 8 }
  end
  -- waypoints and spawn spheres have no child objects, so their block ends at the first '};'
  for name, body in txt:gmatch('new BeamNGWaypoint%(([%w_]+)%)%s*{(.-)};') do add(name, body) end
  for name, body in txt:gmatch('new SpawnSphere%(([%w_]+)%)%s*{(.-)};') do add(name, body) end
  return true
end

-- a level object by name (some layouts use waypoints placed in the level itself)
local function sceneWaypoint(name)
  local ok, p = pcall(function()
    local o = scenetree and scenetree.findObject(name)
    if not o then return nil end
    local pos, s = o:getPosition(), o:getScale()
    return { x = pos.x, y = pos.y, z = pos.z, r = s and max(s.x, s.y, s.z) or 8 }
  end)
  return ok and p or nil
end

-- 'city_race_1' -> 'City race 1', 'asphaltHillclimb2' -> 'Asphalt hillclimb 2'
local function prettify(track)
  local s = track:gsub('(%l)(%u)', '%1 %2'):gsub('(%a)(%d)', '%1 %2'):gsub('_', ' '):lower()
  return (s:gsub('^%l', string.upper))
end

local function title(key, track)
  local t
  if type(key) == 'string' and key ~= '' then
    local ok, v = pcall(function() return type(_tr) == 'function' and _tr(key) or nil end)
    if ok and type(v) == 'string' and v ~= '' and v ~= key then t = v end
  end
  return t or prettify(track)
end

local function cpList(names, pos, missing)
  local out = {}
  for _, n in ipairs(names) do
    local p = pos[n] or sceneWaypoint(n)
    if p then out[#out + 1] = { name = n, x = p.x, y = p.y, z = p.z, r = p.r }
    else missing[#missing + 1] = n end
  end
  return out
end

-- the classic format: one course per direction
local function readClassic(dir, track, d, out)
  local base = {}
  prefabWaypoints(dir .. track .. '.prefab', base)
  for _, rev in ipairs({ false, true }) do
    if not rev or d.reversible then
      local pos = {}
      for k, v in pairs(base) do pos[k] = v end
      prefabWaypoints(dir .. track .. (rev and '_reverse' or '_forward') .. '.prefab', pos)
      local cfg = {}
      for i, c in ipairs(type(d.lapConfig) == 'table' and d.lapConfig or {}) do cfg[i] = c end
      local startN, finishN = d.startLineCheckpoint, d.finishLineCheckpoint
      if rev then
        for i = 1, floor(#cfg / 2) do cfg[i], cfg[#cfg + 1 - i] = cfg[#cfg + 1 - i], cfg[i] end
        if not d.closed then startN, finishN = finishN, startN end
      end
      local names, missing = {}, {}
      local closed = d.closed == true
      if closed then
        names[1] = finishN or cfg[#cfg]
        for i, c in ipairs(cfg) do if c ~= names[1] then names[#names + 1] = c end end
      else
        -- no start line: the car starts at the spawn sphere
        local spawn = track .. (rev and '_standingReverse_spawn' or '_standing_spawn')
        names[1] = startN or (pos[spawn] and spawn) or nil
        for _, c in ipairs(cfg) do names[#names + 1] = c end
        if finishN and finishN ~= names[#names] then names[#names + 1] = finishN end
      end
      local cps = cpList(names, pos, missing)
      out[#out + 1] = { track = track, reverse = rev, closed = closed, nameKey = d.name, lapCount = d.lapCount,
        cps = cps, missing = missing, format = 'json' }
    end
  end
end

-- the race.json format: follow the segments from the start node
local function readRace(track, d, out)
  local cls = type(d.classification) == 'table' and d.classification or {}
  if cls.branching then return 'branching' end
  local nodes, nextOf, prevOf = {}, {}, {}
  for _, n in ipairs(type(d.pathnodes) == 'table' and d.pathnodes or {}) do
    if type(n.pos) == 'table' then nodes[n.oldId] = { name = n.name, x = n.pos[1], y = n.pos[2], z = n.pos[3], r = n.radius or 8 } end
  end
  for _, s in ipairs(type(d.segments) == 'table' and d.segments or {}) do
    if nextOf[s.from] then return 'branching' end
    nextOf[s.from], prevOf[s.to] = s.to, s.from
  end
  local starts = {}
  for _, p in ipairs(type(d.startPositions) == 'table' and d.startPositions or {}) do
    if type(p.pos) == 'table' then starts[p.oldId] = { name = p.name, x = p.pos[1], y = p.pos[2], z = p.pos[3], r = 8 } end
  end
  for _, rev in ipairs({ false, true }) do
    if not rev or cls.reversible then
      local link = rev and prevOf or nextOf
      local first = rev and d.endNode or d.startNode
      if cls.closed then first = d.startNode end
      local cps, seen, id = {}, {}, first
      while id and nodes[id] and not seen[id] do
        seen[id] = true
        cps[#cps + 1] = nodes[id]
        id = link[id]
      end
      if not cls.closed then
        local sp = starts[rev and d.reverseStartPosition or d.defaultStartPosition]
        if sp then table.insert(cps, 1, sp) end
      end
      if #cps >= 2 then
        out[#out + 1] = { track = track, reverse = rev, closed = cls.closed == true, nameKey = d.name,
          lapCount = d.defaultLaps, cps = cps, missing = {}, format = 'race.json' }
      end
    end
  end
end

-- every layout of a level: { id, track, name, reverse, closed, cps = { {name, x, y, z, r}... }, missing }
-- (cps[1] is the start line, which is also the finish on a closed course)
M.list = function(level)
  local dir = '/levels/' .. level .. '/quickrace/'
  local out, skipped = {}, {}
  local files = FS:directoryExists(dir) and FS:findFiles(dir, '*.json', 0, true, false) or {}
  table.sort(files)
  local have = {}
  for _, f in ipairs(files) do have[f:match('[^/]+$')] = true end
  for _, f in ipairs(files) do
    local fname = f:match('[^/]+$')
    local track, ext = fname:match('^(.-)%.(race%.json)$')
    if not track then track, ext = fname:match('^(.-)%.(json)$') end
    -- a track with both files is read from its .json, as the game lists it
    if track and not (ext == 'race.json' and have[track .. '.json']) and not fname:match('%.prefab%.json$') then
      local ok, d = pcall(jsonReadFile, f)
      if ok and type(d) == 'table' and d.procedural then
        skipped[#skipped + 1] = track .. ' (procedural)'
      elseif ok and type(d) == 'table' then
        local before = #out
        local why
        if ext == 'race.json' then why = readRace(track, d, out) else readClassic(dir, track, d, out) end
        if why then skipped[#skipped + 1] = track .. ' (' .. why .. ')' end
        for i = before + 1, #out do
          local c = out[i]
          c.id = 'qr_' .. track .. (c.reverse and '_rev' or '')
          c.name = title(c.nameKey, track) .. (c.reverse and ' (reverse)' or '')
          c.file = f
        end
      else
        skipped[#skipped + 1] = track .. ' (unreadable)'
      end
    end
  end
  if #skipped > 0 then log('I', logTag, 'quick race layouts skipped: ' .. table.concat(skipped, ', ')) end
  return out
end

-- road graph ------------------------------------------------------------------------

local function nodePos(id)
  local n = map.getMap().nodes[id]
  return n and n.pos
end

-- graph nodes from a to b (positions {x, y, z}): the game's point to point path, else a node path
-- between the nearest roads
local function legNodes(a, b)
  if map.getPointToPointPath then
    local ok, p = pcall(map.getPointToPointPath, vec3(a.x, a.y, a.z), vec3(b.x, b.y, b.z))
    if ok and type(p) == 'table' and #p > 0 then return p end
  end
  -- the shortest of the paths between the two road ends nearest a and the two nearest b
  local a1, a2 = map.findClosestRoad(vec3(a.x, a.y, a.z))
  local b1, b2 = map.findClosestRoad(vec3(b.x, b.y, b.z))
  if not (a1 and b1) then return {} end
  local function d(p, q) return (p and q) and sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2) or math.huge end
  local best, bestL = {}, math.huge
  for _, s in ipairs({ a1, a2 }) do
    for _, e in ipairs({ b1, b2 }) do
      local ok, p = pcall(map.getPath, s, e)
      if ok and type(p) == 'table' and #p > 0 then
        local l = d(nodePos(s), a) + d(nodePos(e), b)
        for i = 2, #p do l = l + d(nodePos(p[i]), nodePos(p[i - 1])) end
        if l < bestL then best, bestL = p, l end
      end
    end
  end
  return best
end

local function dot2(ax, ay, bx, by) return ax * bx + ay * by end

-- a polyline a -> graph nodes -> b, without nodes behind a or beyond b
local function leg(a, b)
  local ids = legNodes(a, b)
  local ps = {}
  for _, id in ipairs(ids) do
    local p = nodePos(id)
    if p then ps[#ps + 1] = { p.x, p.y, p.z } end
  end
  -- a lies between the first two nodes: the first is behind it (likewise b and the last two)
  while #ps >= 2 and dot2(a.x - ps[1][1], a.y - ps[1][2], ps[2][1] - ps[1][1], ps[2][2] - ps[1][2]) > 0 do table.remove(ps, 1) end
  while #ps >= 2 and dot2(b.x - ps[#ps][1], b.y - ps[#ps][2], ps[#ps - 1][1] - ps[#ps][1], ps[#ps - 1][2] - ps[#ps][2]) > 0 do table.remove(ps) end
  if #ps == 1 then
    -- one node left: keep it only if it lies ahead of a and before b
    local p = ps[1]
    if dot2(p[1] - a.x, p[2] - a.y, b.x - a.x, b.y - a.y) <= 0 or dot2(p[1] - b.x, p[2] - b.y, a.x - b.x, a.y - b.y) <= 0 then ps = {} end
  end
  local line = { { a.x, a.y, a.z } }
  for _, p in ipairs(ps) do line[#line + 1] = p end
  line[#line + 1] = { b.x, b.y, b.z }
  local len, direct = 0, sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
  for i = 2, #line do len = len + sqrt((line[i][1] - line[i - 1][1]) ^ 2 + (line[i][2] - line[i - 1][2]) ^ 2) end
  -- no road between them, or a road that goes the long way round: a straight line (both
  -- checkpoints on one stretch of road leave no node between them: straight too, and right)
  if #ids == 0 or len > 5 * direct + 400 then return { line[1], line[#line] }, true end
  return line, false
end

-- Out-and-back spikes: a checkpoint placed beside the road or on a short spur, or a side street's
-- node at a junction, pulls the line in and back out (sometimes across both carriageways). Where
-- the line comes back within SPIKE_R of a point after going further than that, within SPIKE_MAX
-- metres of line, the excursion is cut; its checkpoints move to the nearer end. A longer one is a
-- real turn-around and stays.
local SPIKE_MAX, SPIKE_R = 80, 6
local function dist2(p, q) return (p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2 end
local function dropSpikes(line)
  for i = 1, #line - 2 do
    local a = line[i]
    if not a then break end
    local s, back, far = 0, nil, 0
    for j = i + 1, #line do
      s = s + sqrt(dist2(line[j - 1], line[j]))
      if s > SPIKE_MAX then break end
      local d = dist2(a, line[j])
      if d < SPIKE_R * SPIKE_R and far > (SPIKE_R + 2) ^ 2 then back = j end
      far = max(far, d)
    end
    if back then
      local b = line[back]
      for _ = i + 1, back - 1 do
        local v = table.remove(line, i + 1)
        if v.cps then
          local to = dist2(v, a) <= dist2(v, b) and a or b
          to.cps = to.cps or {}
          for _, n in ipairs(v.cps) do table.insert(to.cps, n) end
        end
      end
    end
  end
end

-- the course line every STEP metres, and the index of each checkpoint on it
M.buildLine = function(c)
  local cps = c.cps
  local order = {}
  for i = 1, #cps do order[i] = cps[i] end
  if c.closed then order[#order + 1] = cps[1] end
  local poly, approx = {}, false
  for i = 1, #order - 1 do
    local l, straight = leg(order[i], order[i + 1])
    approx = approx or straight
    if i == 1 then l[1].cps = { 1 } poly[1] = l[1] end
    for k = 2, #l do poly[#poly + 1] = l[k] end
    poly[#poly].cps = { i + 1 }
  end
  -- resample (checkpoints keep their tags), then cut the spikes
  local pts, carry = { { poly[1][1], poly[1][2], poly[1][3], cps = poly[1].cps } }, 0
  for i = 2, #poly do
    local a, b = poly[i - 1], poly[i]
    local d = sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
    local s = STEP - carry
    while s <= d do
      local f = s / d
      pts[#pts + 1] = { a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f }
      s = s + STEP
    end
    carry = d - (s - STEP)
    if b.cps then
      if carry > STEP / 2 then pts[#pts + 1] = { b[1], b[2], b[3] } carry = 0 end
      local p = pts[#pts]
      p.cps = p.cps or {}
      for _, k in ipairs(b.cps) do table.insert(p.cps, k) end
    end
  end
  dropSpikes(pts)
  -- the last point of a closed course is the start line again: the route closes on itself
  local n = (c.closed and #pts > 2) and #pts - 1 or #pts
  local cpAt = {}
  for i, p in ipairs(pts) do
    for _, k in ipairs(p.cps or {}) do cpAt[k] = min(i, n) end
    p.cps = nil
  end
  if c.closed then pts[#pts] = nil cpAt[#cps + 1] = nil end
  return pts, cpAt, approx
end

M.prettify = prettify
return M
