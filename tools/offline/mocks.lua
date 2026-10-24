-- Minimal BeamNG GE API mocks for running coDriverAnalysis.lua offline.
unpack = unpack or table.unpack
local V = {}
V.__index = V
function vec3(x, y, z)
  if type(x) == 'table' then return setmetatable({ x = x.x, y = x.y, z = x.z }, V) end
  return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V)
end
function V.__add(a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
function V.__sub(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
function V.__mul(a, b) if type(a) == 'number' then a, b = b, a end return vec3(a.x * b, a.y * b, a.z * b) end
function V:length() return math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) end
function V:normalized() local l = self:length() if l < 1e-12 then return vec3(0, 0, 0) end return vec3(self.x / l, self.y / l, self.z / l) end

function log(level, tag, msg) if level == 'E' or level == 'W' then print('[' .. level .. '] ' .. tostring(msg)) end end
settings = { getValue = function(k) return nil end }
-- game paths like /levels/x/... are relative to the working directory here
local function vp(f) return (tostring(f):gsub('^/', '')) end
FS = {
  fileExists = function(_, f) return fileExistsJS(vp(f)) end,
  directoryExists = function(_, d) return fileExistsJS(vp(d)) end, directoryCreate = function(_, d) mkdirJS(d) end,
  findFiles = function() return {} end, removeFile = function(_, f) removeFileJS(f) end,
}
function jsonReadFile(f) return readJSON(vp(f)) end
function readFile(f) return readTextJS(vp(f)) end
function jsonWriteFile(f, obj) writeText(f, jsonEncode(obj)) return true end
function writeFile(f, data) writeText(f, data) return true end
GUI = {}
guihooks = { trigger = function(name, data) GUI[name] = data end, message = function() end }
getCurrentLevelIdentifier = function() return MOCK_LEVEL or 'test' end

-- road graph: MOCK_NODES = { id = { pos = vec3, radius = r } }, MOCK_EDGES = { {a, b}, ... }
MOCK_NODES, MOCK_EDGES = {}, {}
map = {
  getMap = function() return { nodes = MOCK_NODES } end,
  findBestRoad = function(pos)
    local best, ba, bb = math.huge
    for _, e in ipairs(MOCK_EDGES) do
      local a, b = MOCK_NODES[e[1]].pos, MOCK_NODES[e[2]].pos
      local ex, ey = b.x - a.x, b.y - a.y
      local l2 = ex * ex + ey * ey
      local f = l2 > 0 and math.max(0, math.min(1, ((pos.x - a.x) * ex + (pos.y - a.y) * ey) / l2)) or 0
      local d = (pos.x - a.x - ex * f) ^ 2 + (pos.y - a.y - ey * f) ^ 2
      if d < best then best, ba, bb = d, e[1], e[2] end
    end
    if not ba then return nil end
    return ba, bb, math.sqrt(best)
  end,
  -- shortest path over MOCK_EDGES (both ways), a list of node ids
  getPath = function(a, b)
    local dist, prev, done = { [a] = 0 }, {}, {}
    local adj = {}
    for _, e in ipairs(MOCK_EDGES) do
      local l = (MOCK_NODES[e[1]].pos - MOCK_NODES[e[2]].pos):length()
      adj[e[1]] = adj[e[1]] or {} table.insert(adj[e[1]], { e[2], l })
      adj[e[2]] = adj[e[2]] or {} table.insert(adj[e[2]], { e[1], l })
    end
    while true do
      local u, du = nil, math.huge
      for n, d in pairs(dist) do if not done[n] and d < du then u, du = n, d end end
      if not u or u == b then break end
      done[u] = true
      for _, nb in ipairs(adj[u] or {}) do
        local d = du + nb[2]
        if not dist[nb[1]] or d < dist[nb[1]] then dist[nb[1]], prev[nb[1]] = d, u end
      end
    end
    if not dist[b] then return {} end
    local out, n = {}, b
    while n do table.insert(out, 1, n) n = prev[n] end
    return out
  end,
}
map.findClosestRoad = map.findBestRoad

-- walls: MOCK_WALLS = { {x1, y1, x2, y2}, ... } of infinite height; the ground is z = 0
RAYS = 0
function castRayStatic(o, d, maxDist)
  RAYS = RAYS + 1
  local best = maxDist
  if d.z < -0.5 then -- down: the ground
    local t = o.z / -d.z
    if t >= 0 and t < best then best = t end
    return best
  end
  local h = math.sqrt(d.x * d.x + d.y * d.y)
  if h < 1e-9 then return best end
  for _, w in ipairs(MOCK_WALLS or {}) do
    local x1, y1, x2, y2 = w[1], w[2], w[3], w[4]
    local sx, sy = x2 - x1, y2 - y1
    local den = d.x * sy - d.y * sx
    if math.abs(den) > 1e-12 then
      local t = ((x1 - o.x) * sy - (y1 - o.y) * sx) / den
      local u = ((x1 - o.x) * d.y - (y1 - o.y) * d.x) / den
      if t >= 0 and u >= 0 and u <= 1 and t < best then best = t end
    end
  end
  return best
end

-- compact JSON, for payload sizes
local function enc(v, out)
  local tv = type(v)
  if tv == 'table' then
    if #v > 0 or next(v) == nil then
      out[#out + 1] = '['
      for i = 1, #v do if i > 1 then out[#out + 1] = ',' end enc(v[i], out) end
      out[#out + 1] = ']'
    else
      out[#out + 1] = '{'
      local first = true
      for k, x in pairs(v) do
        if type(x) ~= 'function' then
          if not first then out[#out + 1] = ',' end
          first = false
          out[#out + 1] = '"' .. tostring(k) .. '":'
          enc(x, out)
        end
      end
      out[#out + 1] = '}'
    end
  elseif tv == 'number' then
    if v == math.floor(v) and math.abs(v) < 1e15 then out[#out + 1] = string.format('%d', v) else out[#out + 1] = string.format('%.14g', v) end
  elseif tv == 'string' then out[#out + 1] = string.format('%q', v)
  elseif tv == 'boolean' then out[#out + 1] = tostring(v)
  else out[#out + 1] = 'null' end
end
function jsonEncode(v) local o = {} enc(v, o) return table.concat(o) end
os.clock = nowSecs
