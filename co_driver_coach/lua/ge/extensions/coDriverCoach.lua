-- Co-Driver Coach
-- Reads the road network ahead of the player car and talks like a rally co-driver:
-- corner calls (pacenotes), braking cues, a shift light and understeer/oversteer hints.
-- Voice uses the rally co-driver clips that ship with the game.
-- Read-only: it never sends any input to the vehicle.

local M = {}
local logTag = 'coDriverCoach'

local abs, min, max, sqrt, floor, exp, cos, pi = math.abs, math.min, math.max, math.sqrt, math.floor, math.exp, math.cos, math.pi
local atan2 = math.atan2
local G = 9.81
local DS = 4          -- m between resampled path points
local WIN = 3         -- curvature smoothing half-window, in samples (7 samples = 28 m)
local K_ON = 1 / 350  -- curvature (1/m) where a bend starts to count as a corner
local LANE = 1.5      -- m of lateral room assumed for straightening a line through a bend

local settingsPath = '/settings/coDriverCoach.json'
local voicepackDir = '/lua/ge/extensions/gameplay/rally/compositors/voicepacks/'

local surfaces = {
  tarmac = { grip = 0.8,  brake = 0.8 },
  gravel = { grip = 0.65, brake = 0.6 },
  snow   = { grip = 0.35, brake = 0.3 },
}
local surfaceOrder = { 'tarmac', 'gravel', 'snow' }

local defaults = {
  enabled = true,
  voice = true,
  voicepack = 'ak_2026-04-16',
  voiceOutput = 'plain', -- 'plain' plays clips directly; 'intercom' uses the game's rally intercom channel
  voiceVolume = 2.0,     -- the plain output is mixed quieter than the intercom; above 1 amplifies
  style = 'numbers',     -- 'numbers': 6 fastest .. 1 slowest; 'words': flat/easy/medium/hard
  surface = 'tarmac',
  callAheadSec = 4.5,    -- how many seconds before a corner it gets called
  crests = true,
  brakeVoice = true,
  carControl = true,
  distanceCalls = true,
  consoleMap = true,     -- draw the map on the car's navigation screen, when the car has one
  frameScreen = true,    -- tilt the driver camera just enough to see that screen (once per car)  -- "two hundred, three left" when a corner is called from far away
  chatter = true,        -- spoken slide, shift, stage and debrief lines (when the voice has them)
  toasts = false,        -- also show calls in the stock Messages app
  brakeAid = 'bar',      -- braking cue on the strip: 'off', 'bar' (fills up to the brake point) or 'zone' (bar + the zone drawn on the road)
  recce = true,          -- on a route with recce notes, call those (coDriverCoach/recce.lua)
  lastScenario = '',     -- scenario menu: last scenario loaded, car choice and stage length
  scenarioOwnCar = false,
  stageKm = 0,
}
local cfg = {}

-- state ----------------------------------------------------------------------

local clock = 0
local vehId = nil
local lastVel = nil
local speed, latAcc, slip = 0, 0, 0
local vehData = {}
local steerGain, steerGainCount = {}, {}
local hint = { text = nil, level = 0, untilT = 0 }
local hintCondTime = 0
local notes = {}
local onRoad, usingRoute = false, false
local pathInfo = {}
local viewSamples, viewPos, viewDir = {}, nil, nil -- last road samples and car pose, for the top-down map
local called, brakeCalled = {}, {}
local brakeNowCalled = {}
local brake = { state = 'none' }
local shift = nil
local lastCall = nil
local callLog = {}
local pathTimer, vehTimer, uiTimer = 0, 0, 0
local errorLogged = {}       -- subsystem -> true once its first error is logged

-- drive review state
local HARSH_JERK = 35        -- m/s^3 of g-force change that counts as a harsh input (AI driving averages ~7)
local historyPath = '/settings/coDriverCoach_history.json'
local jerk, jerkLat = 0, 0   -- rate of change of g-force (m/s^3), from the car's smoothed sensors
local lastG = nil
local lastDamage = nil
local HARSH_LAT = 25         -- m/s^3 of sideways g change that counts as a harsh steering input
local drive = nil            -- metrics for the drive in progress
local summary = nil          -- debrief of the last finished drive
local parkedTime = 0
local trackedCorners = {}
local roadNear, offRoad = false, false
local lastBrakeState = 'none'
local findTracked            -- defined in the drive review section
local lastEventKind, lastEventT = nil, -10
local endDrive               -- defined in the drive review section
local updateScenario         -- defined in the scenarios section
-- shared with the scenarios module: the active GPS stage { node, pos, km }, the result of the last
-- finished one, the scenario being loaded (stepped through by updateScenario) and the menu state
local S = { stage = nil, stageResult = nil, pendingScenario = nil, menuOpen = false }

-- Per-car grip learned from what the driver has actually shown, keyed by car config and
-- surface, so targets fit a slick-tyred track car as well as a van. It is the 3rd highest of the
-- 12 best clean corner (or braking) peaks seen (see learnGrip): two freak values can't inflate it,
-- and gentle driving can't pull it down. Older profiles keep their value until 6 clean peaks exist.
local carsPath = '/settings/coDriverCoach_cars.json'
local carKey = nil
local learned = {}           -- { lat, brake (g), latPeaks, brkPeaks, legacy } for the current car
local lonAcc, latSus, decelSus = 0, 0, 0
local lastImpactT = -10      -- last time the car took a hit (no learning or smoothness right after)

local function gripG() return max(surfaces[cfg.surface].grip, learned.lat or 0) end
local function brakeG() return max(surfaces[cfg.surface].brake, learned.brake or 0) end

-- settings -------------------------------------------------------------------

local function loadSettings()
  local saved = FS:fileExists(settingsPath) and jsonReadFile(settingsPath) or {}
  for k, v in pairs(defaults) do
    if saved[k] ~= nil and type(saved[k]) == type(v) then cfg[k] = saved[k] else cfg[k] = v end
  end
  if not surfaces[cfg.surface] then cfg.surface = defaults.surface end
end

local function saveSettings()
  jsonWriteFile(settingsPath, cfg, true)
end

-- A custom (unsaved) car config is the whole serialized parts tree, which made keys of 100+ KB:
-- keep saved .pc paths as they are and shorten anything else to a hash.
local function configId(cfgString)
  local s = tostring(cfgString)
  if #s < 200 and not s:find('[{}\n]') then return s end
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return string.format('custom-%08x', h)
end

local function loadCars()
  local t = FS:fileExists(carsPath) and jsonReadFile(carsPath)
  if type(t) ~= 'table' then return {} end
  -- migrate old long keys (model|<parts tree>|surface) to the short form, values kept
  local moved = false
  for k, v in pairs(t) do
    if #k >= 200 then
      local model, mid, surface = k:match('^([^|]*)|(.*)|([^|]*)$')
      if model then
        local nk = model .. '|' .. configId(mid) .. '|' .. surface
        if t[nk] == nil then t[nk] = v end
        t[k], moved = nil, true
      end
    end
  end
  if moved then jsonWriteFile(carsPath, t, true) end
  return t
end

local function numList(x)
  local out = {}
  for _, v in ipairs(type(x) == 'table' and x or {}) do if tonumber(v) then out[#out + 1] = tonumber(v) end end
  return out
end

local function loadCarProfile(veh)
  carKey = veh and (tostring(veh:getJBeamFilename()) .. '|' .. configId(veh.partConfig) .. '|' .. cfg.surface) or nil
  local p = carKey and loadCars()[carKey]
  if type(p) ~= 'table' then learned = {} return end
  learned = { lat = tonumber(p.lat), brake = tonumber(p.brake), latPeaks = numList(p.latPeaks), brkPeaks = numList(p.brkPeaks) }
  learned.legacy = #learned.latPeaks == 0 and learned.lat ~= nil -- an old max-ever value, replaced once peaks exist
end

local function saveCarProfile()
  if not carKey or not (learned.lat or learned.brake) then return end
  local cars = loadCars()
  cars[carKey] = { lat = learned.lat, brake = learned.brake, latPeaks = learned.latPeaks, brkPeaks = learned.brkPeaks, v = 2 }
  jsonWriteFile(carsPath, cars, true)
end

-- voice ------------------------------------------------------------------------

local clips = {}        -- word -> list of { file, len } (several takes per word in some packs)
local clipCount = 0
local voicepacks = {}
local voiceQueue = {}
local voiceBusyUntil = 0
local droppingPhrase = false

local function scanVoicepacks()
  voicepacks = {}
  for _, path in ipairs(FS:findFiles(voicepackDir, 'metadata.json', -1, true, false)) do
    local name = path:match('voicepacks/([^/]+)/metadata%.json$')
    if name then table.insert(voicepacks, name) end
  end
  table.sort(voicepacks)
end

local function packHasWords(newClips)
  local probe = cfg.style == 'words' and 'medium_left' or 'three_left'
  return newClips[probe] ~= nil and newClips.brake ~= nil
end

local function loadVoicepack(name)
  local metaPath = voicepackDir .. name .. '/metadata.json'
  local meta = FS:fileExists(metaPath) and jsonReadFile(metaPath)
  if type(meta) ~= 'table' then return false end
  local newClips, count = {}, 0
  for fname, info in pairs(meta) do
    local file = voicepackDir .. name .. '/audio/' .. fname
    if type(info) == 'table' and FS:fileExists(file) then
      local word = fname:gsub('^pacenote_', ''):gsub('%.ogg$', ''):gsub('_%d+$', '')
      newClips[word] = newClips[word] or {}
      table.insert(newClips[word], { file = file, len = tonumber(info.audioLen) or 0.8 })
      count = count + 1
    end
  end
  if count == 0 or not packHasWords(newClips) then return false end
  clips, clipCount = newClips, count
  return true
end

local function ensureVoicepack()
  if loadVoicepack(cfg.voicepack) then return end
  scanVoicepacks()
  for _, name in ipairs(voicepacks) do
    if loadVoicepack(name) then
      cfg.voicepack = name
      return
    end
  end
  clips, clipCount = {}, 0
  log('W', logTag, 'no rally voicepack with audio found; voice calls are off')
end

-- Queue a phrase (list of words). Urgent phrases jump ahead of queued phrases,
-- but never cut into the phrase that is already being spoken. Chatter (remarks, progress,
-- shift calls) only plays when nothing else is queued or speaking, so it never delays a call.
local function say(words, urgent, chat)
  if not cfg.voice then return end
  if chat and (voiceQueue[1] or clock < voiceBusyUntil) then return end
  local items = {}
  for _, w in ipairs(words) do
    local takes = clips[w]
    if takes then items[#items + 1] = { clip = takes[math.random(#takes)], t = clock } end
  end
  if not items[1] then return end
  items[1].first = true
  local at = #voiceQueue + 1
  if urgent then
    at = 1
    while voiceQueue[at] and not voiceQueue[at].first do at = at + 1 end
  end
  for i, it in ipairs(items) do table.insert(voiceQueue, at + i - 1, it) end
end

-- The first of these words the current voice can say (newer recordings have words older packs lack).
local function pick(...)
  for i = 1, select('#', ...) do
    local w = select(i, ...)
    if w and clips[w] then return w end
  end
end

-- Build a word list, skipping words the voice doesn't have.
local function list(...)
  local t = {}
  for i = 1, select('#', ...) do
    local w = select(i, ...)
    if w then t[#t + 1] = w end
  end
  return t
end

local scheduled = {} -- phrases spoken at a set time, e.g. the stage countdown
local function sayAt(delay, words)
  if words[1] then scheduled[#scheduled + 1] = { t = clock + delay, words = words } end
end

local function playClip(clip)
  if cfg.voiceOutput == 'intercom' then
    Engine.Audio.intercomPlayPacenote({ filename = clip.file })
  else
    Engine.Audio.playOnce('AudioGui', clip.file, { volume = cfg.voiceVolume })
  end
end

local function updateVoice()
  local i = 1
  while scheduled[i] do
    if clock >= scheduled[i].t then say(table.remove(scheduled, i).words) else i = i + 1 end
  end
  if clock < voiceBusyUntil then return end
  while voiceQueue[1] do
    local it = table.remove(voiceQueue, 1)
    if it.first then droppingPhrase = (clock - it.t) > 2.5 end -- skip calls that are no longer timely
    if not droppingPhrase then
      playClip(it.clip)
      voiceBusyUntil = clock + it.clip.len + 0.04
      return
    end
  end
end

-- road ahead -------------------------------------------------------------------

local function wrapAngle(a)
  while a > pi do a = a - 2 * pi end
  while a < -pi do a = a + 2 * pi end
  return a
end

local function projectOnSegment(p, a, b)
  local ab = b - a
  local t = clamp((p - a):dot(ab) / max(ab:squaredLength(), 1e-6), 0, 1)
  return a + ab * t
end

-- Follow the GPS route when one is set and the car is on it.
local function routeAhead(pos, horizon, dir)
  local rp = core_groundMarkers and core_groundMarkers.routePlanner
  local path = rp and rp.path
  if type(path) ~= 'table' or #path < 2 then return nil end
  local bestI, bestD, bestP
  for i = 1, min(#path - 1, 40) do
    local p = projectOnSegment(pos, vec3(path[i].pos), vec3(path[i + 1].pos))
    local d = (pos - p):length()
    if not bestD or d < bestD then bestI, bestD, bestP = i, d, p end
  end
  if not bestD or bestD > 25 then return nil end
  -- the route has to lead roughly the way the car is facing
  local ahead = vec3(path[min(bestI + 1, #path)].pos)
  for k = bestI + 1, min(#path, bestI + 6) do
    ahead = vec3(path[k].pos)
    if (ahead - bestP):length() > 15 then break end
  end
  local rdir = ahead - bestP
  if dir and rdir:length() > 1 and rdir:normalized():dot(vec3(dir.x, dir.y, 0):normalized()) < -0.2 then return nil end
  local pts, len = { bestP }, 0
  for i = bestI + 1, #path do
    local p = vec3(path[i].pos)
    len = len + (p - pts[#pts]):length()
    pts[#pts + 1] = p
    if len >= horizon then break end
  end
  return pts
end

-- Otherwise walk the road graph, taking the straightest legal branch at junctions.
local function graphAhead(pos, dir, horizon)
  local mapData = map.getMap()
  local nodes = mapData and mapData.nodes
  if not nodes or not next(nodes) then return nil end
  -- map.nodes[].links holds each edge on one node only; the pathfinder graph has both directions
  local gp = map.getGraphpath()
  local graph = gp and gp.graph
  if not graph then return nil end
  local ok, n1, n2, dist = pcall(map.findBestRoad, pos, dir)
  if not ok or not n1 or not nodes[n1] or not nodes[n2] or not dist or dist > 25 then return nil end

  local prev, cur = n1, n2
  if (nodes[n2].pos - nodes[n1].pos):dot(dir) < 0 then prev, cur = n2, n1 end
  local pts = { projectOnSegment(pos, nodes[prev].pos, nodes[cur].pos) }
  local len, visited = 0, {}
  for _ = 1, 600 do
    local cp = nodes[cur].pos
    len = len + (cp - pts[#pts]):length()
    pts[#pts + 1] = cp
    if len >= horizon then break end
    visited[cur] = true
    local inDir = (cp - nodes[prev].pos):normalized()
    local best, bestScore
    for nid, edge in pairs(graph[cur] or {}) do
      if nid ~= prev and not visited[nid] and nodes[nid] and (not edge.oneWay or edge.inNode == cur) then
        local score = (nodes[nid].pos - cp):normalized():dot(inDir)
        if (edge.drivability or 1) < 0.25 then score = score - 0.5 end
        if not bestScore or score > bestScore then best, bestScore = nid, score end
      end
    end
    if not best then break end
    prev, cur = cur, best
  end
  return pts
end

local function resample(pts)
  local out = { vec3(pts[1]) }
  local carry = 0 -- distance from the last output sample to the start of the current segment
  for i = 1, #pts - 1 do
    local a, b = pts[i], pts[i + 1]
    local ab = b - a
    local segLen = ab:length()
    local d = DS - carry
    while d <= segLen do
      out[#out + 1] = a + ab * (d / segLen)
      d = d + DS
    end
    carry = segLen - (d - DS)
  end
  return out
end

-- corner grading ---------------------------------------------------------------

local numberWords = { 'one', 'two', 'three', 'four', 'five', 'six' }
local gradeWords = { 'hard', 'hard', 'medium', 'medium', 'easy', 'flat' }

local function cornerCall(note)
  local dir = note.sign > 0 and 'left' or 'right'
  local Dir = note.sign > 0 and 'Left' or 'Right'
  local D = note.sign > 0 and 'L' or 'R'
  if note.R < 18 and note.angleDeg > 120 then
    if note.R < 10 then return 'tight_hairpin_' .. dir, 'Tight hairpin ' .. Dir, 0, 'HP' .. D end
    return 'hairpin_' .. dir, 'Hairpin ' .. Dir, 0, 'HP' .. D
  end
  if note.angleDeg >= 70 and note.angleDeg <= 110 and note.R < 20 and note.length < 35 then
    return 'square_' .. dir, 'Square ' .. Dir, 1, 'SQ' .. D
  end
  local R, grade = note.Reff, nil
  if R >= 350 then grade = note.angleDeg > 45 and 6 or nil
  elseif R >= 180 then grade = 6
  elseif R >= 110 then grade = 5
  elseif R >= 70 then grade = 4
  elseif R >= 45 then grade = 3
  elseif R >= 28 then grade = 2
  else grade = 1 end
  if not grade then return nil end
  if cfg.style == 'words' then
    local w = gradeWords[grade]
    return w .. '_' .. dir, w:sub(1, 1):upper() .. w:sub(2) .. ' ' .. Dir, grade, w:sub(1, 1):upper() .. D
  end
  return numberWords[grade] .. '_' .. dir, grade .. ' ' .. Dir, grade, grade .. D
end

local function analyzePath(s)
  local n = #s
  local out = {}
  if n < 2 * WIN + 3 then return out end

  local heading, turn, k = {}, {}, {}
  for i = 1, n - 1 do
    local d = s[i + 1] - s[i]
    heading[i] = atan2(d.y, d.x)
  end
  turn[1], turn[n] = 0, 0
  for i = 2, n - 1 do turn[i] = wrapAngle(heading[i] - heading[i - 1]) end -- +left
  for i = 1, n do
    local sum = 0
    for j = max(1, i - WIN), min(n, i + WIN) do sum = sum + turn[j] end
    k[i] = sum / ((2 * WIN + 1) * DS)
  end

  -- group samples into same-direction bends (short straights between same-way bends are merged)
  local bends = {}
  local i = 1
  while i <= n do
    if abs(k[i]) > K_ON then
      local sign = k[i] > 0 and 1 or -1
      local j = i
      while j < n and k[j + 1] * sign > K_ON * 0.6 do j = j + 1 end
      local last = bends[#bends]
      if last and last.sign == sign and i - last.i1 <= 3 then
        last.i1 = j
      else
        bends[#bends + 1] = { i0 = i, i1 = j, sign = sign }
      end
      i = j + 1
    else
      i = i + 1
    end
  end

  local grip = gripG()
  for _, b in ipairs(bends) do
    local angle, kMax, apex = 0, 0, b.i0
    for j = b.i0, b.i1 do
      angle = angle + turn[j]
      if abs(k[j]) > kMax then kMax, apex = abs(k[j]), j end
    end
    angle = abs(angle)
    if angle > 0.26 then -- ignore bends under ~15 degrees
      local note = { kind = 'corner', sign = b.sign, angleDeg = angle * 180 / pi }
      note.dist = (b.i0 - 1 + WIN * 0.5) * DS
      note.endDist = max((b.i1 - 1 - WIN * 0.5) * DS, note.dist)
      note.apexDist = (apex - 1) * DS
      note.length = note.endDist - note.dist
      note.R = 1 / kMax
      note.Reff = note.R + LANE / max(1 - cos(min(angle * 0.5, pi * 0.5)), 1e-3)
      note.vSafe = min(sqrt(grip * G * note.Reff), 90)
      note.entryPos, note.apexPos = s[min(b.i0 + WIN, n)], s[apex]
      note.complete = b.i1 < n - WIN - 1

      local word, text, grade, short = cornerCall(note)
      if word then
        note.words, note.text, note.grade, note.short = { word }, text, grade, short
        if note.length > 160 and note.angleDeg > 90 and grade and grade >= 2 then
          table.insert(note.words, 'very_long')
          note.text = note.text .. ' very long'
        elseif note.length > 90 and note.angleDeg > 60 and grade and grade >= 2 then
          table.insert(note.words, 'long')
          note.text = note.text .. ' long'
        end
        if note.length > 30 then
          local mid = floor((b.i0 + b.i1) / 2)
          local k1, k2 = 0, 0
          for j = b.i0, mid do k1 = k1 + abs(k[j]) end
          for j = mid + 1, b.i1 do k2 = k2 + abs(k[j]) end
          k1, k2 = k1 / (mid - b.i0 + 1), k2 / max(b.i1 - mid, 1)
          if k2 > k1 * 1.6 then
            table.insert(note.words, 'tightens')
            note.text = note.text .. ' tightens'
          elseif k1 > k2 * 1.6 then
            table.insert(note.words, 'opens')
            note.text = note.text .. ' opens'
          end
        end
        out[#out + 1] = note
      end
    end
  end

  if cfg.crests then
    local lastFeature = -100
    local function convexity(c) return ((s[c].z - s[c - 3].z) - (s[c + 3].z - s[c].z)) / (3 * DS) end
    for c = 5, n - 4 do
      local change = convexity(c)
      local slopeIn = (s[c].z - s[c - 3].z) / (3 * DS)
      local word, text, short
      if change > 0.06 and slopeIn > 0.02 and change >= convexity(c - 1) and change >= convexity(c + 1) then
        if change > 0.30 then word, text, short = 'jump', 'Jump', 'JP'
        elseif change > 0.18 then word, text, short = 'big_crest', 'Big crest', 'CR'
        elseif change > 0.09 then word, text, short = 'crest', 'Crest', 'CR'
        else word, text, short = 'small_crest', 'Small crest', 'CR' end
      elseif change < -0.12 and slopeIn < -0.02 and change <= convexity(c - 1) and change <= convexity(c + 1) then
        word, text, short = 'dip', 'Dip', 'DP'
      end
      if word and c - lastFeature > 8 then
        local d = (c - 1) * DS
        out[#out + 1] = {
          kind = 'crest', feature = word, dist = d, endDist = d, apexDist = d, entryPos = s[c], apexPos = s[c], complete = true,
          words = { word }, text = text, grade = 7, short = short,
        }
        lastFeature = c
      end
    end
    -- a crest inside a corner is called as part of it: "three left over crest"
    for i = #out, 1, -1 do
      local f = out[i]
      if f.kind == 'crest' and f.feature ~= 'dip' then
        for _, cn in ipairs(out) do
          if cn.kind == 'corner' and f.dist >= cn.dist and f.dist <= cn.endDist then
            table.insert(cn.words, 'over_crest')
            cn.text = cn.text .. ' over crest'
            table.remove(out, i)
            break
          end
        end
      end
    end
  end

  table.sort(out, function(a, b) return a.dist < b.dist end)
  return out
end

-- calling ----------------------------------------------------------------------

local function wasCalled(list, note)
  for _, e in ipairs(list) do
    if (e.pos - note.entryPos):length() < 15 or (e.apex - note.apexPos):length() < 15 then return true end
  end
  return false
end

local function markCalled(list, note)
  for i = #list, 1, -1 do
    if clock - list[i].t > 90 then table.remove(list, i) end
  end
  list[#list + 1] = { pos = vec3(note.entryPos), apex = vec3(note.apexPos), t = clock }
end

local function announce(text)
  lastCall = text
  table.insert(callLog, 1, { t = clock, text = text })
  callLog[21] = nil
  if cfg.toasts then guihooks.message(text, 3, 'coDriverCoach') end
end

local recce -- recce pacenotes (coDriverCoach/recce.lua), set below

local function callNotes()
  local callDist = max(speed * cfg.callAheadSec, 35)
  local inRecce, recceAhead = false, nil
  if recce then inRecce, recceAhead = recce.update(callDist, speed >= 4) end
  if inRecce then -- this part of the route has recce notes: the coach's own calls are only marked, so it
    -- doesn't repeat them when it takes over (the lap ends, or the recce does)
    for _, note in ipairs(notes) do
      if note.dist > callDist then break end
      if note.dist > -5 and not wasCalled(called, note) then markCalled(called, note) end
    end
    return
  end
  if speed < 4 then return end
  for i, note in ipairs(notes) do
    if note.dist > callDist or not note.complete then break end
    if recceAhead and note.dist <= recceAhead and not wasCalled(called, note) then
      markCalled(called, note) -- the recce called it just before it ended
    end
    if note.dist > -5 and not wasCalled(called, note) then
      markCalled(called, note)
      if note.dist >= 6 then -- too late to be useful otherwise
        local words, text = { unpack(note.words) }, note.text
        if note.kind == 'corner' and note.vSafe then -- a big speed drop is worth a warning
          if note.vSafe < speed * 0.35 then
            table.insert(words, 'double_caution')
            text = text .. ', double caution'
          elseif note.vSafe < speed * 0.5 then
            table.insert(words, 'caution')
            text = text .. ', caution'
          end
        end
        local last = note
        for j = i + 1, min(i + 1, #notes) do
          local nxt = notes[j]
          local gap = nxt.dist - last.endDist
          if gap > 40 or not nxt.complete or wasCalled(called, nxt) then break end
          local link = gap < 15 and 'into' or 'and'
          table.insert(words, link)
          for _, w in ipairs(nxt.words) do table.insert(words, w) end
          text = text .. ' ' .. link .. ' ' .. nxt.text
          markCalled(called, nxt)
          last = nxt
        end
        if recce then recce.onCall(note.dist, words, text) end -- kept without the distance, which depends on speed
        if cfg.distanceCalls and note.dist >= 120 and not voiceQueue[1] then -- called from far away: say how far
          local best
          for _, b in ipairs({ 100, 150, 200, 250, 300, 400, 500 }) do
            if not best or abs(b - note.dist) < abs(best - note.dist) then best = b end
          end
          if pick(tostring(best)) then
            table.insert(words, 1, tostring(best))
            text = best .. ', ' .. text
          end
        end
        say(words)
        announce(text)
      end
    end
  end
end

local function updateBrake()
  local decel = brakeG() * G
  local worst
  for _, note in ipairs(notes) do
    if note.kind == 'corner' and note.dist > -2 and note.vSafe < speed then
      local brakeDist = (speed * speed - note.vSafe * note.vSafe) / (2 * decel)
      local pointDist = note.dist + 0.3 * max(note.apexDist - note.dist, 0)
      local margin = pointDist - brakeDist -- metres left before you must be braking
      if not worst or margin < worst.margin then worst = { note = note, margin = margin } end
    end
  end

  if not worst then
    brake = { state = 'none' }
    return
  end
  local state = 'none'
  if worst.margin < 0 then state = 'late'
  elseif worst.margin < speed * 1.2 then state = 'brake'
  elseif worst.margin < speed * 3 then state = 'soon' end
  brake = { state = state, margin = worst.margin, target = worst.note.vSafe, text = worst.note.text }

  -- brake cues are attached to the corner they belong to and judged when that corner is done
  local braking = (vehData.brake or 0) > 0.2
  local tc = drive and findTracked(worst.note)
  if (state == 'brake' or state == 'late') and not wasCalled(brakeCalled, worst.note) then
    markCalled(brakeCalled, worst.note)
    if cfg.brakeVoice and (vehData.brake or 0) < 0.3 then
      local w = 'brake'
      if state == 'late' then
        w = worst.margin < -speed * 0.5 and pick('brake_hard', 'brake_now', 'brake') or pick('brake_now', 'brake')
        markCalled(brakeNowCalled, worst.note)
      end
      say({ w }, true)
    end
    if tc and not tc.cue then
      tc.cue = {}
      if not braking then drive.pendingBrake = { t = clock, target = worst.note.vSafe, tc = tc } end
    end
  end
  -- still off the brakes when it is already too late: braking point too deep
  if tc and tc.cue and state == 'late' and lastBrakeState ~= 'late' and not braking then tc.cue.late = true end
  if state == 'late' and not braking and cfg.brakeVoice and not wasCalled(brakeNowCalled, worst.note) then
    markCalled(brakeNowCalled, worst.note)
    local w = worst.margin < -speed * 0.5 and pick('brake_hard', 'brake_now') or pick('brake_now')
    if w then say({ w }, true) end
  end
  lastBrakeState = state
end

-- car control ------------------------------------------------------------------

local function updateDynamics(dt, vel, dir)
  local dirH = vec3(dir.x, dir.y, 0)
  local l = dirH:length()
  if l < 0.1 then return end
  dirH = dirH * (1 / l)
  local rightH = vec3(dirH.y, -dirH.x, 0)
  local vF, vR = vel.x * dirH.x + vel.y * dirH.y, vel.x * rightH.x + vel.y * rightH.y
  speed = vel:length()
  local a = 1 - exp(-dt / 0.15)
  if lastVel then
    local acc = (vel - lastVel) * (1 / dt)
    latAcc = latAcc + (acc:dot(rightH) - latAcc) * a
    lonAcc = lonAcc + (acc:dot(dirH) - lonAcc) * a
  end
  lastVel = vec3(vel)
  local s = vF > 2 and atan2(vR, vF) or 0 -- >0: car travelling to the right of where it points
  slip = slip + (s - slip) * a
end

-- Grip learning, per corner (or braking) event rather than per frame. A collision shows up as a
-- lateral spike a frame or two before its damage report arrives, so an event's peak only counts
-- once 3 s have passed without an impact. Samples where the lateral g doesn't match speed x yaw
-- rate (wall scrapes, kerb strikes, landings) are ignored. The learned value is the 3rd highest
-- of the 12 best clean peaks (x 0.92 margin): a demonstrated limit that up to two freak values
-- can't inflate and that easy corners can't pull down.
local learnGrip
do
  local KEEP_PEAKS, MIN_PEAKS, RANK = 12, 6, 3
  local ev, pending, lastYaw = nil, {}, nil

  local function commit(key, peaksKey, value)
    local list = learned[peaksKey] or {}
    list[#list + 1] = floor(min(value / G * 0.92, 1.8) * 1000 + 0.5) / 1000
    table.sort(list, function(a, b) return a > b end) -- best first; only the best few matter
    while #list > KEEP_PEAKS do table.remove(list) end
    learned[peaksKey] = list
    if #list >= MIN_PEAKS then
      learned[key] = list[RANK]
      if key == 'lat' then learned.legacy = nil end
    end
  end

  learnGrip = function(dt, slipDeg, hinting)
    local veh = getPlayerVehicle(0)
    if not veh or dt <= 0 then return end
    local dir = veh:getDirectionVector()
    local yaw = atan2(dir.y, dir.x)
    local yawRate = lastYaw and wrapAngle(yaw - lastYaw) / dt or 0
    lastYaw = yaw
    local clean = speed > 10 and slipDeg < 5 and not hinting and clock - lastImpactT > 3
    local consistent = abs(abs(latAcc) - abs(speed * yawRate)) < 0.25 * G + 0.15 * abs(latAcc)
    local braking = (vehData.brake or 0) > 0.5
    if latSus > 0.35 * G or (braking and decelSus > 0.35 * G) then
      ev = ev or { t0 = clock, lat = 0, brk = 0 }
      if clean and consistent then
        ev.lat = max(ev.lat, latSus)
        if braking then ev.brk = max(ev.brk, decelSus) end
      end
    elseif ev and latSus < 0.25 * G and decelSus < 0.25 * G then
      ev.tEnd = clock
      pending[#pending + 1] = ev
      ev = nil
    end
    -- commit finished events that stayed clear of impacts for 3 s
    local i = 1
    while i <= #pending do
      local e = pending[i]
      if lastImpactT >= e.t0 - 0.5 then
        table.remove(pending, i)
      elseif clock - e.tEnd > 3 then
        if e.lat > 0.4 * G then commit('lat', 'latPeaks', e.lat) end
        if e.brk > 0.4 * G then commit('brake', 'brkPeaks', e.brk) end
        table.remove(pending, i)
      else
        i = i + 1
      end
    end
  end

  -- read-only view of the learning, for the console and tests
  M.gripDebug = function()
    return { event = ev and { lat = ev.lat / G, brk = ev.brk / G } or nil, pending = #pending,
      latPeaks = #(learned.latPeaks or {}), brkPeaks = #(learned.brkPeaks or {}), lat = learned.lat, brake = learned.brake,
      legacy = learned.legacy, carKey = carKey, latSus = latSus / G }
  end
end

local lastSlideVoiceT, saveWatch = -10, nil
local function slideVoice(kind)
  if not cfg.chatter or clock - lastSlideVoiceT < 3 then return end
  lastSlideVoiceT = clock
  if kind == 'bigSlide' then
    say(list(pick('catch_it', 'caution')), true)
    saveWatch = { t = clock, impact = lastImpactT }
  elseif kind == 'oversteer' then
    say(list(pick('oversteer')), true)
  elseif kind == 'understeer' then
    say(list(pick('understeer'), pick('ease_off')), true)
  end
end

local function updateCarControl(dt)
  local steer = abs(vehData.steer or 0)
  local slipDeg = abs(slip) * 180 / pi
  local kPath = abs(latAcc) / max(speed * speed, 1)
  local bin = clamp(floor(speed / 7) + 1, 1, 8)

  -- learn how this car normally responds to steering, per speed band, while it has grip
  if speed > 6 and steer > 0.04 and steer < 0.4 and abs(latAcc) < 0.3 * G and slipDeg < 3 then
    local r = kPath / steer
    steerGainCount[bin] = (steerGainCount[bin] or 0) + 1
    local g = steerGain[bin] or r
    steerGain[bin] = g + (r - g) / min(steerGainCount[bin], 200)
  end

  local text, level, kind
  if speed > 8 and slipDeg > 8 then
    local side = slip > 0 and 'right' or 'left'
    if slipDeg > 20 then
      text, level, kind = 'BIG SLIDE - countersteer ' .. side .. ', ease throttle', 2, 'bigSlide'
    else
      text, level, kind = 'OVERSTEER - countersteer ' .. side .. ', ease throttle', 1, 'oversteer'
    end
  elseif speed > 9 and steer > 0.2 and slipDeg < 6 and (steerGainCount[bin] or 0) > 40
      and abs(latAcc) > 0.35 * G and kPath < 0.6 * steerGain[bin] * steer then
    text, level, kind = 'UNDERSTEER - ease off, unwind the wheel', 1, 'understeer'
  end

  hintCondTime = text and hintCondTime + dt or 0
  if text and hintCondTime > 0.2 then
    hint = { text = text, level = level, untilT = clock + 1.0 }
    -- one event per slide: a new kind, or the same kind after a 2 s gap
    if kind ~= lastEventKind or clock - lastEventT > 2 then
      if drive then
        drive[kind] = drive[kind] + 1
        drive.incidents = drive.incidents + 1
      end
      slideVoice(kind)
    end
    lastEventKind, lastEventT = kind, clock
  elseif hint.untilT < clock then
    hint = { text = nil, level = 0, untilT = 0 }
  end

  -- caught a big slide without hitting anything: "nice save"
  if saveWatch and not text and clock - lastEventT > 0.8 then
    if lastImpactT == saveWatch.impact and speed > 5 and cfg.chatter then say(list(pick('nice_save'))) end
    saveWatch = nil
  elseif saveWatch and clock - saveWatch.t > 8 then
    saveWatch = nil
  end

  -- learn the grip this car has shown: sustained g while gripping (see learnGrip)
  local aSus = 1 - exp(-dt / 0.6)
  latSus = latSus + (abs(latAcc) - latSus) * aSus
  decelSus = decelSus + (max(-lonAcc, 0) - decelSus) * aSus
  learnGrip(dt, slipDeg, text ~= nil)
end

local function computeShift()
  local d = vehData
  shift = nil
  if not d.maxrpm or d.maxrpm < 500 or d.gearboxMode ~= 'realistic' then return end
  local gear = tonumber(tostring(d.gear or ''):match('^[MS]?(%d+)$'))
  if not gear then return end
  if d.rpm > 0.93 * d.maxrpm and d.throttle > 0.4 then
    shift = 'up'
  elseif gear > 1 and d.brake > 0.2 and d.rpm < 0.4 * d.maxrpm and brake.state ~= 'none' then
    shift = 'down'
  end
end

local lastShiftCall, lastShiftT = nil, -10
local function updateShift()
  computeShift()
  if shift ~= lastShiftCall then
    if shift and cfg.chatter and clock - lastShiftT > 2 then
      say(list(pick(shift == 'up' and 'shift_up' or 'shift_down')), false, true)
      lastShiftT = clock
    end
    lastShiftCall = shift
  end
end

local cornerVoice, crashVoice, roadVoice, resetCornerStreak
do
  -- Short remarks after a corner: rare praise, honest when it went wrong, a pat on the back for a clean run.
  local lastFeedbackT, lastHotT, cleanStreak = -60, -60, 0
  cornerVoice = function(c)
    if not cfg.chatter then return end
    local r = c.minSpeed / max(c.vSafe, 1)
    cleanStreak = c.incident and 0 or cleanStreak + 1
    local w
    if c.incident and r > 1.05 then
      if clock - lastHotT > 10 then w = pick('too_hot'); lastHotT = clock end
    elseif cleanStreak > 0 and cleanStreak % 10 == 0 then
      w = pick('clean_so_far')
    elseif clock - lastFeedbackT > 45 and math.random() < 0.35 then
      if not c.incident and r >= 0.9 and r <= 1.15 then
        w = pick('good_corner')
      elseif not c.incident and c.grade and c.grade <= 4 and c.minSpeed > 5 and r < 0.65 then
        w = pick('too_slow')
      end
    end
    if w then
      say({ w }, false, true)
      lastFeedbackT = clock
    end
  end

  local lastCrashVoiceT = -60
  crashVoice = function()
    if not cfg.chatter then return end
    local w = clock - lastCrashVoiceT < 30 and pick('are_you_okay', 'ouch') or pick('ouch')
    lastCrashVoiceT = clock
    if w then say({ w }, true) end
  end

  local lastRoadVoiceT = -60
  roadVoice = function(word)
    if not cfg.chatter or clock - lastRoadVoiceT < 5 then return end
    lastRoadVoiceT = clock
    say(list(pick(word)), false, true)
  end

    resetCornerStreak = function() cleanStreak = 0 end

end

-- Play one line right away, even while the coach is switched off ("coach off").
local function playNow(word)
  local takes = cfg.voice and clips[word]
  if takes then playClip(takes[1]) end
end

-- Snapshot of the vehicle's electrics, sent back from the vehicle VM.
local vehDataCmd = [[local e=electrics.values obj:queueGameEngineLua(string.format("if coDriverCoach then coDriverCoach.onVehicleData(%d,%q,%.1f,%.1f,%.3f,%.3f,%.3f,%q,%.0f,%.3f,%.3f) end",obj:getId(),tostring(e.gear),e.rpm or 0,e.maxrpm or 0,e.throttle or 0,e.brake or 0,e.steering_input or 0,tostring(e.gearboxMode),beamstate and beamstate.damage or 0,sensors.gx2 or 0,sensors.gy2 or 0))]]

local function onVehicleData(id, gear, rpm, maxrpm, throttle, brakeInput, steer, gearboxMode, damage, gx, gy)
  if id ~= vehId then return end
  vehData = { gear = gear, rpm = rpm, maxrpm = maxrpm, throttle = throttle, brake = brakeInput, steer = steer, gearboxMode = gearboxMode }
  if gx and gy then -- gx2 is lateral, gy2 longitudinal
    if lastG and clock > lastG.t then
      local dt = clock - lastG.t
      jerkLat = abs(gx - lastG.x) / dt
      jerk = sqrt((gx - lastG.x) ^ 2 + (gy - lastG.y) ^ 2) / dt
    end
    lastG = { x = gx, y = gy, t = clock }
  end
  if damage then
    if lastDamage and damage - lastDamage > 200 then
      lastImpactT = clock
      if drive then table.insert(drive.impacts, clock) end
    end
    lastDamage = damage
  end
  -- crash = more than 1000 J of damage within about a second (the game's AI uses the same threshold)
  if drive and damage then
    if not drive.damageBase or damage < drive.damageBase or clock - drive.damageBaseT > 1 then
      drive.damageBase, drive.damageBaseT = damage, clock
    elseif damage - drive.damageBase > 1000 then
      if clock - drive.lastCrash > 3 then
        drive.crashes = drive.crashes + 1
        crashVoice()
        drive.incidents = drive.incidents + 1
        drive.lastCrash = clock
      end
      drive.damageBase, drive.damageBaseT = damage, clock
    end
  end
end

-- drive review -------------------------------------------------------------------
-- A drive starts when the car moves and ends when you press END, park for 20 s,
-- switch vehicle or leave the level. Each aspect gets a 0-100 score and a letter.

local function newDrive()
  return {
    time = 0, dist = 0, maxSpeed = 0, incidents = 0,
    corners = {},
    brakeCues = 0, brakeSlow = 0, brakeMissed = 0, brakeLate = 0, brakeBrave = 0, pendingBrake = nil,
    oversteer = 0, bigSlide = 0, understeer = 0,
    buckets = {}, bucket = nil, impacts = {}, lastHarsh = -10, lastHarshLat = -10,
    jerkSum = 0, jerkLatSum = 0, jerkTime = 0, harsh = 0, harshLat = 0,
    pedalTime = 0, pedalAnalog = 0,
    roadTime = 0, offRoadTime = 0, wasOff = false, resets = 0, crashes = 0, lastCrash = -10,
    manualTime = 0, limiterTime = 0, lugTime = 0,
  }
end

findTracked = function(note)
  for _, tc in ipairs(trackedCorners) do
    if (tc.apex - note.apexPos):length() < 20 or (tc.entry - note.entryPos):length() < 20 then return tc end
  end
end

-- A finished corner: record it, and judge its brake cue by how the corner turned out.
local function finishCorner(d, tc)
  local corner = {
    text = tc.text, vSafe = tc.vSafe, grade = tc.grade, minSpeed = tc.minSpeed,
    incident = d.incidents > tc.incidentsAtEntry,
  }
  table.insert(d.corners, corner)
  cornerVoice(corner)
  local cue = tc.cue
  if not cue then return end
  d.brakeCues = d.brakeCues + 1
  local wentWrong = corner.incident or corner.minSpeed > 1.1 * corner.vSafe
  if wentWrong then
    if cue.missed then d.brakeMissed = d.brakeMissed + 1
    elseif cue.late then d.brakeLate = d.brakeLate + 1
    elseif cue.slow then d.brakeSlow = d.brakeSlow + 1 end
  elseif cue.missed or cue.late then
    d.brakeBrave = d.brakeBrave + 1 -- braked later than the cue and still made the corner cleanly
  end
end

-- Follow each corner from approach to exit and record the slowest speed through it.
local function trackCorners()
  if not drive then return end
  local insideDist = DS * (WIN * 0.5 + 0.5) -- a corner we are in starts this far ahead (path begins at the car)
  for _, note in ipairs(notes) do
    if note.kind == 'corner' and note.complete and note.dist < 120 then
      local tc = findTracked(note)
      if not tc then
        tc = { minSpeed = math.huge, inside = false }
        table.insert(trackedCorners, tc)
      end
      tc.entry, tc.apex, tc.seen = vec3(note.entryPos), vec3(note.apexPos), clock
      if not tc.inside then tc.text, tc.vSafe, tc.grade = note.text, note.vSafe, note.grade end
      if note.dist <= insideDist and note.endDist >= 0 then
        if not tc.inside then
          tc.inside = true
          tc.incidentsAtEntry = drive.incidents
        end
        tc.minSpeed = min(tc.minSpeed, speed)
      end
    end
  end
  for i = #trackedCorners, 1, -1 do
    local tc = trackedCorners[i]
    if clock - tc.seen > 0.6 then -- left behind
      if tc.inside and tc.minSpeed < math.huge and tc.minSpeed > 2 then finishCorner(drive, tc) end
      table.remove(trackedCorners, i)
    end
  end
end

-- Smoothness is collected in 1 s buckets and only counted once we know no crash or reset
-- happened around them, so impacts don't count as "jerky driving".
local function commitBuckets(d, all)
  if d.bucket and all then
    table.insert(d.buckets, d.bucket)
    d.bucket = nil
  end
  while d.buckets[1] and (all or d.buckets[1].t0 < clock - 4) do
    local b = table.remove(d.buckets, 1)
    local clean = true
    for _, t in ipairs(d.impacts) do
      if b.t0 > t - 3 and b.t0 < t + 3 then clean = false end
    end
    if clean then
      d.jerkSum, d.jerkLatSum, d.jerkTime = d.jerkSum + b.sum, d.jerkLatSum + b.sumLat, d.jerkTime + b.time
      d.harsh, d.harshLat = d.harsh + b.harsh, d.harshLat + b.harshLat
    end
  end
end

local function updateDriveMetrics(dt)
  if not drive then
    if speed > 3 then
      drive = newDrive()
      resetCornerStreak()
      if cfg.chatter and not S.stage then say(list(pick('lets_go')), false, true) end
    end
    return
  end
  local d, v = drive, vehData
  d.time = d.time + dt
  d.dist = d.dist + speed * dt
  d.maxSpeed = max(d.maxSpeed, speed)

  if speed > 3 then
    local b = d.bucket
    if not b or clock - b.t0 >= 1 then
      if b then table.insert(d.buckets, b) end
      b = { t0 = clock, sum = 0, sumLat = 0, time = 0, harsh = 0, harshLat = 0 }
      d.bucket = b
    end
    b.sum = b.sum + min(jerk, 40) * dt -- cap so one bump can't dominate
    b.sumLat = b.sumLat + min(jerkLat, 40) * dt
    b.time = b.time + dt
    if jerk > HARSH_JERK and clock - d.lastHarsh > 1 then
      b.harsh = b.harsh + 1
      d.lastHarsh = clock
    end
    if jerkLat > HARSH_LAT and clock - d.lastHarshLat > 1 then
      b.harshLat = b.harshLat + 1
      d.lastHarshLat = clock
    end

    -- keyboard pedals are only ever fully on or off; analogue pedals spend time in between
    local th, br = v.throttle or 0, v.brake or 0
    if th > 0.05 or br > 0.05 then
      d.pedalTime = d.pedalTime + dt
      if (th > 0.05 and th < 0.9) or (br > 0.05 and br < 0.9) then d.pedalAnalog = d.pedalAnalog + dt end
    end
  end
  commitBuckets(d, false)

  if speed > 2 and roadNear then
    d.roadTime = d.roadTime + dt
    if offRoad then
      d.offRoadTime = d.offRoadTime + dt
      if not d.wasOff then
        d.incidents = d.incidents + 1
        d.offSince, d.offSaid = clock, false
      end
      if not d.offSaid and clock - d.offSince > 1.0 then
        d.offSaid = true
        roadVoice('off_the_road')
      end
    elseif d.wasOff and d.offSaid then
      roadVoice('back_on_road')
    end
    d.wasOff = offRoad
  end

  if v.gearboxMode == 'realistic' and v.maxrpm and v.maxrpm > 500 then
    local gear = tonumber(tostring(v.gear or ''):match('^[MS]?(%d+)$'))
    if gear then
      d.manualTime = d.manualTime + dt
      if v.rpm > 0.97 * v.maxrpm then d.limiterTime = d.limiterTime + dt end
      if gear > 1 and v.rpm < 0.3 * v.maxrpm and v.throttle > 0.7 then d.lugTime = d.lugTime + dt end
    end
  end

  -- how the driver answered the last brake cue
  local pb = d.pendingBrake
  if pb then
    if (v.brake or 0) > 0.2 then
      if clock - pb.t > 1.0 then pb.tc.cue.slow = true end
      d.pendingBrake = nil
    elseif clock - pb.t > 2.0 then
      if speed > pb.target * 1.05 then pb.tc.cue.missed = true end -- lifting off and still making the speed is fine
      d.pendingBrake = nil
    end
  end

  parkedTime = speed < 0.5 and parkedTime + dt or 0
  if parkedTime > 20 then
    local ok, err = xpcall(endDrive, debug.traceback, false)
    if not ok then log('E', logTag, 'ending the drive failed: ' .. tostring(err)) end
  end
end

-- grading ------------------------------------------------------------------------

local function pct(a, b) return b > 0 and a / b * 100 or 0 end

local letterCuts = {
  { 97, 'A+' }, { 93, 'A' }, { 90, 'A-' }, { 87, 'B+' }, { 83, 'B' }, { 80, 'B-' },
  { 77, 'C+' }, { 73, 'C' }, { 70, 'C-' }, { 67, 'D+' }, { 63, 'D' }, { 60, 'D-' },
}
local function letter(score)
  for _, c in ipairs(letterCuts) do
    if score >= c[1] then return c[2] end
  end
  return 'F'
end

-- the next grade up from a score: { threshold, letter }, or nil at the top
local function nextCut(score)
  for i = #letterCuts, 1, -1 do
    if letterCuts[i][1] > score then return letterCuts[i] end
  end
end

-- A lever is one thing you can improve: points per unit, how many units you could win
-- back at most, whether units are whole (counts) and how to say "improve by u units".
local function lever(per, most, whole, say) return { per = per, most = max(most, 0), whole = whole, say = say } end

-- Cheapest combination of levers that closes `need` points; returns the advice text.
local function planTo(levers, need)
  table.sort(levers, function(a, b) return a.most * a.per > b.most * b.per end)
  local parts = {}
  for _, lv in ipairs(levers) do
    if need <= 0.01 then break end
    if lv.most > 0 and lv.per > 0 then
      local units = need / lv.per
      if lv.whole then units = math.ceil(units - 1e-6) end
      units = min(units, lv.most)
      parts[#parts + 1] = lv.say(units)
      need = need - units * lv.per
    end
  end
  if not parts[1] then return nil end
  return table.concat(parts, ', and '), need <= 0.01
end

-- What to work on for each aspect: concrete tips plus a mindset. The first tip doubles
-- as the one-liner shown when you open that aspect in the debrief.
local advice = {
  braking = function(d)
    local tips = {}
    if d.brakeMissed >= d.brakeLate then
      tips[1] = 'When you hear "brake" or the panel turns orange, be on the pedal within half a second. Make it a reflex, not a decision.'
    else
      tips[1] = 'Your braking points are too deep. Pick a marker (a sign, a tree, a shadow) a car length earlier than feels natural, and brake there every time.'
    end
    tips[2] = 'Brake hardest in a straight line, then bleed off the pedal as you turn in.'
    return tips, { title = 'Slow in, fast out', text = 'The time is won on the exit, not on the brakes. Arrive calm, leave fast.' }
  end,
  entry = function(d)
    return {
      'Be at the panel\'s target speed (the "≤" number) before you turn the wheel, not halfway through the corner.',
      'On the corners listed, enter a little slower and see how much earlier you can get back on the throttle.',
    }, { title = 'Patience at turn-in', text = 'Arriving a little slower costs a tenth. A slide or a trip off the road costs seconds.' }
  end,
  pace = function(d)
    return {
      'You slow down more than the corners need. Brake a little later and lighter, and trust the target speed: it comes from grip you have already shown in this car.',
      'Look further up the road. At the apex your eyes should already be on the exit.',
    }, { title = 'Commit', text = 'Hesitation is slow. Decide early, then trust the decision all the way through the corner.' }
  end,
  control = function(d)
    local tips = {}
    if d.understeer > d.oversteer + d.bigSlide then
      tips[1] = 'Understeer means too much speed or too much steering. Ease off and unwind a little; adding lock will not help.'
    else
      tips[1] = 'Be gentle with the throttle mid-corner. Add power only once you start unwinding the wheel.'
    end
    tips[2] = 'If the car slides, look where you want to go and make one early, small correction instead of several big ones.'
    return tips, { title = 'Calm hands', text = 'Every input is a request to the tyres, not a command. Ask politely and they keep gripping.' }
  end,
  smooth = function(d, digital)
    if digital then
      return {
        'Steer with one smooth motion into the corner and one smooth motion out, instead of quick taps and corrections.',
        'On keyboard pedals, lift off the throttle a moment before turning in rather than braking and steering at the same instant.',
      }, { title = 'Smooth is fast', text = 'If a run feels slow and calm, it is usually quicker than it feels.' }
    end
    return {
      'Squeeze the pedals: take about a second to go from nothing to full brake or full throttle.',
      'Turn in with one smooth steering motion instead of several small corrections.',
    }, { title = 'Smooth is fast', text = 'If a run feels slow and calm, it is usually quicker than it feels.' }
  end,
  road = function(d)
    return {
      'Drive the next run at about 90% and only build speed once you have a clean one.',
      'Watch the map panel: when the next corner is red or orange, get set up on the outside of the road early.',
    }, { title = 'To finish first, first you must finish', text = 'A clean run always beats a fast crash. Consistency comes before speed.' }
  end,
  gears = function(d)
    local tips = {}
    if d.limiterTime >= d.lugTime then
      tips[1] = 'Shift up when the SHIFT ▲ light comes on. Sitting on the limiter wastes acceleration.'
    else
      tips[1] = 'Drop a gear before the corner so you leave it in the power band, not bogged down.'
    end
    tips[2] = 'Do your downshifts while braking in a straight line, so you are ready to accelerate at the exit.'
    return tips, { title = 'Listen to the engine', text = 'It tells you when it wants the next gear. Shift on its rhythm, not by habit.' }
  end,
}

local function plural(n, one, many) return n == 1 and one or many end

local function scoreDrive(d, mul, unit)
  local aspects = {}
  local digital = d.pedalTime > 20 and d.pedalAnalog / d.pedalTime < 0.3

  -- score = 100 minus the levers' penalties; nil score = not enough data to grade
  local function add(key, name, weight, measure, score, detail, levers, stats)
    aspects[#aspects + 1] = {
      key = key, name = name, weight = weight, measure = measure, detail = detail, stats = stats, levers = levers,
      score = score and floor(clamp(score, 0, 100) + 0.5) or nil,
    }
  end
  local n = #d.corners

  -- braking: a missed or late cue only counts when that corner then went wrong
  local c = d.brakeCues
  local bm, bl, bs = 70 / max(c, 1), 45 / max(c, 1), 15 / max(c, 1)
  add('braking', 'Braking', 1.2,
    'Each brake cue is checked against how its corner turned out. Missing the cue or braking too late only costs you when that corner then went wrong: over the target speed, a slide, running wide or a crash.',
    c >= 2 and (100 - bm * d.brakeMissed - bl * d.brakeLate - bs * d.brakeSlow) or nil,
    c >= 2 and string.format('%d braking zones: %d missed, %d too late, %d slow to react', c, d.brakeMissed, d.brakeLate, d.brakeSlow)
      or 'Not enough braking zones to grade',
    {
      lever(bm, d.brakeMissed, true, function(u) return string.format('react to %d more brake %s that you missed', u, plural(u, 'cue', 'cues')) end),
      lever(bl, d.brakeLate, true, function(u) return string.format('brake earlier for %d more %s', u, plural(u, 'corner', 'corners')) end),
      lever(bs, d.brakeSlow, true, function(u) return string.format('get on the brake within a second %d more %s', u, plural(u, 'time', 'times')) end),
    },
    d.brakeBrave > 0 and { string.format('%d %s braked later than the cue and still went cleanly. Nice; that is not held against you.', d.brakeBrave, plural(d.brakeBrave, 'corner was', 'corners were')) } or nil)

  -- corner entry
  local over, messy, worst, ratioSum, ratioN = 0, 0, {}, 0, 0
  for _, k in ipairs(d.corners) do
    local r = k.minSpeed / max(k.vSafe, 1)
    if k.incident and r > 1.05 then
      over = over + 1
      worst[#worst + 1] = k
    elseif k.incident then
      messy = messy + 1
    end
    -- commitment: clean, tight-ish corners only; near-stops (junctions, traffic) don't count against you
    if not k.incident and k.grade and k.grade <= 4 and k.minSpeed > 5 then
      ratioSum, ratioN = ratioSum + min(r, 1.15), ratioN + 1
    end
  end
  local eo, em = 120 / max(n, 1), 50 / max(n, 1)
  add('entry', 'Corner entry', 1.2,
    'Corners where you were over the target speed at the slowest point and then slid, ran wide or crashed (overcooked), or got untidy without being too fast.',
    n >= 3 and (100 - eo * over - em * messy) or nil,
    n >= 3 and string.format('%d of %d corners overcooked, %d untidy', over, n, messy) or 'Not enough corners to grade',
    {
      lever(eo, over, true, function(u) return string.format('overcook %d fewer %s', u, plural(u, 'corner', 'corners')) end),
      lever(em, messy, true, function(u) return string.format('keep %d more %s tidy (no slide or running wide)', u, plural(u, 'corner', 'corners')) end),
    })

  -- commitment
  local ratio = ratioN > 0 and ratioSum / ratioN or 1
  local short = max(0, 0.95 - ratio) * 100 -- full marks from 95% of the target speed
  add('pace', 'Commitment', 0.8,
    'Your slowest speed through clean, tight corners compared with the target speed. Targets come from the grip you have already shown in this car, so this compares you with your own best.',
    ratioN >= 3 and (100 - short) or nil,
    ratioN >= 3 and string.format('Clean corners taken at %d%% of the target speed', floor(ratio * 100 + 0.5)) or 'Not enough tight corners to grade',
    {
      lever(1, short, false, function(u) return string.format('carry clean corners at %d%% of the target speed (now %d%%)', math.ceil(ratio * 100 + u), floor(ratio * 100 + 0.5)) end),
    })

  -- car control
  local n5 = max(n, 5)
  local cs, cb = 120 / n5, 240 / n5
  add('control', 'Car control', 1.0,
    'Oversteer (rear sliding out), big slides and understeer (front pushing wide), counted per corner driven. A big slide counts double.',
    100 - cs * (d.oversteer + d.understeer) - cb * d.bigSlide,
    string.format('%d oversteer, %d big %s, %d understeer', d.oversteer, d.bigSlide, plural(d.bigSlide, 'slide', 'slides'), d.understeer),
    {
      lever(cb, d.bigSlide, true, function(u) return string.format('have %d fewer big %s', u, plural(u, 'slide', 'slides')) end),
      lever(cs, d.oversteer, true, function(u) return string.format('have %d fewer oversteer %s', u, plural(u, 'moment', 'moments')) end),
      lever(cs, d.understeer, true, function(u) return string.format('have %d fewer understeer %s', u, plural(u, 'moment', 'moments')) end),
    })

  -- smoothness (crash moments already left out)
  local minutes = max(d.jerkTime / 60, 0.5)
  if digital then
    local meanLat = d.jerkTime > 0 and d.jerkLatSum / d.jerkTime or 0
    local hpm = d.harshLat / minutes
    add('smooth', 'Smoothness', 0.8,
      'How abruptly the car\'s sideways g-force changes: quick steering jabs and corrections show up as jolts. Keyboard pedals were detected (they are only fully on or off), so only steering is graded. Crash moments are left out.',
      100 - max(0, meanLat - 2.5) * 8 - hpm * 2.5,
      string.format('%.1f harsh steering inputs per minute', hpm),
      {
        lever(2.5, hpm, false, function(u) return string.format('cut harsh steering inputs from %.1f to %.1f per minute', hpm, max(hpm - u, 0)) end),
        lever(8, meanLat - 2.5, false, function(u) return string.format('steer more gently overall (average jolt %.1f → %.1f)', meanLat, meanLat - u) end),
      }, { 'Keyboard pedals detected: graded on steering only.' })
  else
    local mean = d.jerkTime > 0 and d.jerkSum / d.jerkTime or 0
    local hpm = d.harsh / minutes
    add('smooth', 'Smoothness', 0.8,
      'How abruptly the g-forces change: sudden stabs of brake, throttle or steering show up as jolts. Crash moments are left out.',
      100 - max(0, mean - 4) * 5 - hpm * 2,
      string.format('%.1f harsh inputs per minute', hpm),
      {
        lever(2, hpm, false, function(u) return string.format('cut harsh inputs from %.1f to %.1f per minute', hpm, max(hpm - u, 0)) end),
        lever(5, mean - 4, false, function(u) return string.format('smooth out all your inputs a little (jolt score %.1f → %.1f)', mean, mean - u) end),
      })
  end

  -- staying on the road
  local offPct = pct(d.offRoadTime, d.roadTime)
  add('road', 'Staying on road', 1.2,
    'Time with the car past the edge of the road, plus crashes and resets. Driving far away from any road (open off-roading) is not counted.',
    d.roadTime > 20 and (100 - offPct * 4 - d.resets * 8 - d.crashes * 15) or nil,
    string.format('%.1f%% off the road, %d %s, %d %s', offPct, d.crashes, plural(d.crashes, 'crash', 'crashes'), d.resets, plural(d.resets, 'reset', 'resets')),
    {
      lever(15, d.crashes, true, function(u) return string.format('crash %d fewer %s', u, plural(u, 'time', 'times')) end),
      lever(8, d.resets, true, function(u) return string.format('reset %d fewer %s', u, plural(u, 'time', 'times')) end),
      lever(4, offPct, false, function(u) return string.format('spend %.1f%% or less of the time off the road (now %.1f%%)', max(offPct - u, 0), offPct) end),
    })

  -- gears (manual only)
  local manual = d.manualTime > 30 and d.manualTime > 0.3 * d.time
  local limPct, lugPct = pct(d.limiterTime, d.manualTime), pct(d.lugTime, d.manualTime)
  add('gears', 'Gear use', 0.5,
    'Time spent on the rev limiter or lugging (full throttle at very low revs), with a manual gearbox in realistic mode.',
    manual and (100 - limPct * 3 - lugPct * 3) or nil,
    manual and string.format('%.0f%% on the limiter, %.0f%% lugging', limPct, lugPct) or 'Automatic gearbox: not graded',
    {
      lever(3, limPct, false, function(u) return string.format('spend %.0f%% or less on the limiter (now %.0f%%)', max(limPct - u, 0), limPct) end),
      lever(3, lugPct, false, function(u) return string.format('lug the engine %.0f%% or less of the time (now %.0f%%)', max(lugPct - u, 0), lugPct) end),
    })

  -- letters, overall, and what it takes to reach the next letter in each aspect
  local sum, wsum, focus = 0, 0, nil
  for _, a in ipairs(aspects) do
    if a.score then
      a.letter = letter(a.score)
      sum, wsum = sum + a.score * a.weight, wsum + a.weight
      if not focus or a.score < focus.score or (a.score == focus.score and a.weight > focus.weight) then focus = a end
      local nxt = nextCut(a.score)
      if nxt then
        local how = planTo(a.levers, nxt[1] - a.score)
        a.next = { letter = nxt[2], score = nxt[1], how = how }
      end
      local tips = advice[a.key](d, digital)
      a.tip = tips[1]
    end
    a.levers = nil
  end
  local overall = wsum > 0 and sum / wsum or nil

  -- the shortest path to the next overall letter: biggest weighted gains first
  local path
  if overall then
    local nxt = nextCut(floor(overall + 0.5))
    if nxt then
      local gains = {}
      for _, a in ipairs(aspects) do
        if a.score and a.next then
          gains[#gains + 1] = { key = a.key, name = a.name, from = a.letter, to = a.next.letter, gain = (a.next.score - a.score) * a.weight / wsum }
        end
      end
      table.sort(gains, function(x, y) return x.gain > y.gain end)
      local need, steps = nxt[1] - 0.5 - overall, {}
      for _, g in ipairs(gains) do
        if need <= 0 or #steps >= 3 then break end -- three biggest wins at most
        g.gain = floor(g.gain * 10 + 0.5) / 10
        steps[#steps + 1] = g
        need = need - g.gain
      end
      path = { letter = nxt[2], steps = steps, reached = need <= 0 }
    end
  end

  table.sort(worst, function(a, b) return a.minSpeed / a.vSafe > b.minSpeed / b.vSafe end)
  local worstLines = {}
  for i = 1, min(3, #worst) do
    local k = worst[i]
    worstLines[i] = string.format('%s: %d %s (target %d)', k.text, floor(k.minSpeed * mul + 0.5), unit, floor(k.vSafe * mul + 0.5))
  end

  return aspects, overall and floor(overall + 0.5) or nil, focus, worstLines, path, digital
end

local function loadHistory()
  local h = FS:fileExists(historyPath) and jsonReadFile(historyPath)
  return type(h) == 'table' and h or {}
end

local function buildSummary(d, dryRun)
  local mul, unit, distMul, distUnit = 3.6, 'km/h', 0.001, 'km'
  if settings.getValue('uiUnitLength') == 'imperial' then mul, unit, distMul, distUnit = 2.23694, 'mph', 0.000621371, 'mi' end
  local aspects, overall, focus, worstLines, path, digital = scoreDrive(d, mul, unit)
  local s = {
    time = string.format('%d:%02d', floor(d.time / 60), floor(d.time % 60)),
    dist = string.format('%.1f %s', d.dist * distMul, distUnit),
    avgSpeed = floor(d.dist / max(d.time, 1) * mul + 0.5), maxSpeed = floor(d.maxSpeed * mul + 0.5), unit = unit,
    corners = #d.corners, aspects = aspects, path = path,
    calib = string.format('Targets use %.2f g cornering and %.2f g braking%s.', gripG(), brakeG(),
      (learned.lat or 0) <= surfaces[cfg.surface].grip and ' (surface defaults)'
      or (learned.legacy and ', an older estimate that is refined after 6 clean corners'
      or string.format(', learned from your %d cleanest corners in this car', #(learned.latPeaks or {})))),
  }
  if S.stageResult then
    s.stage = string.format('Stage complete: %.0f km in %d:%02d', S.stageResult.km, floor(S.stageResult.time / 60), floor(S.stageResult.time % 60))
    S.stageResult = nil
  end
  if not overall then
    s.tooShort = true
    s.message = 'Not enough driving data to grade this drive.'
    return s
  end
  s.overall = { score = overall, letter = letter(overall) }
  if focus then
    local tips, mentality = advice[focus.key](d, digital)
    s.focus = { key = focus.key, name = focus.name, letter = focus.letter, detail = focus.detail, tips = tips,
      mentality = mentality, next = focus.next, worst = focus.key == 'entry' and worstLines or nil }
  end

  local history = loadHistory()
  local best
  for _, h in ipairs(history) do
    if h.overall and (not best or h.overall > best) then best = h.overall end
  end
  s.isBest = best ~= nil and overall > best
  local prev = history[#history]
  if prev and prev.overall then
    s.previous = { letter = letter(prev.overall), delta = overall - prev.overall }
    if focus and prev.aspects and prev.aspects[focus.key] then s.previous.focusLetter = letter(prev.aspects[focus.key]) end
  end
  local entry = { date = os.date('%Y-%m-%d %H:%M'), overall = overall, aspects = {}, time = d.time, dist = d.dist }
  for _, a in ipairs(aspects) do entry.aspects[a.key] = a.score end
  table.insert(history, entry)
  while #history > 30 do table.remove(history, 1) end
  if not dryRun then jsonWriteFile(historyPath, history, true) end
  return s
end

local function sendSummary()
  guihooks.trigger('CoDriverCoachSummary', summary or { hidden = true })
end

endDrive = function(manual)
  local d = drive
  drive, parkedTime, trackedCorners = nil, 0, {}
  saveCarProfile()
  if not d then
    if manual then
      local recording = coDriverAnalysis and coDriverAnalysis.isRecording() or nil
      summary = { tooShort = true, analysis = recording,
        message = recording and 'No graded drive in progress (it ended when you parked), but your telemetry is still recording.'
          or 'No drive in progress yet. Start driving and press END when you are done.' }
      sendSummary()
    end
    return
  end
  if d.time < 60 or d.dist < 500 then
    if manual then
      summary = { tooShort = true, message = 'That drive was too short to grade. Drive for at least a minute and half a kilometre.',
        analysis = coDriverAnalysis and coDriverAnalysis.isRecording() or nil }
      sendSummary()
    end
    return
  end
  commitBuckets(d, true)
  summary = buildSummary(d)
  summary.analysis = coDriverAnalysis and coDriverAnalysis.isRecording() or nil
  sendSummary()
  if summary.overall then
    if cfg.chatter and pick('drive_complete') then -- "Drive complete. Nice drive. Overall grade B plus. Focus on smoothness."
      local score, l = summary.overall.score, summary.overall.letter
      local praise = score >= 85 and pick('great_drive') or (score >= 70 and pick('nice_drive') or (score < 55 and pick('that_was_messy') or nil))
      local mod = l:sub(2, 2) == '+' and pick('plus') or (l:sub(2, 2) == '-' and pick('minus') or nil)
      local focusWords = { braking = 'focus_braking', entry = 'focus_entry', pace = 'focus_pace', control = 'focus_control',
        smooth = 'focus_smooth', road = 'focus_road', gears = 'focus_gears' }
      local focus = summary.focus and pick(focusWords[summary.focus.key])
      local compare
      if summary.isBest then
        compare = pick('new_best')
      elseif summary.previous then
        local delta = summary.previous.delta
        compare = delta >= 3 and pick('better_than_last') or (delta <= -3 and pick('worse_than_last') or pick('same_as_last'))
      end
      say(list('drive_complete', praise, pick('overall_grade'), pick('grade_' .. l:sub(1, 1):lower()), mod, focus, compare))
    end
    guihooks.message('Drive summary ready: ' .. summary.overall.letter .. ' overall', 6, 'coDriverCoach')
    log('I', logTag, 'drive graded ' .. summary.overall.letter .. ' (' .. summary.overall.score .. ')')
  end
end

-- ui -------------------------------------------------------------------------

-- Road ahead in the car's frame (x = metres right, y = metres forward), for the top-down map.
local function buildView()
  if not onRoad or not viewPos or not viewSamples[2] then return nil end
  local f = vec3(viewDir.x, viewDir.y, 0)
  if f:length() < 0.1 then return nil end
  f = f:normalized()
  local rx, ry = f.y, -f.x
  local function toLocal(p)
    local dx, dy = p.x - viewPos.x, p.y - viewPos.y
    return floor((dx * rx + dy * ry) * 10 + 0.5) / 10, floor((dx * f.x + dy * f.y) * 10 + 0.5) / 10
  end
  local n = #viewSamples
  local function sampleAt(dist) return clamp(floor(dist / DS) + 1, 1, n) end

  local pts = {}
  for i = 1, n do
    local x, y = toLocal(viewSamples[i])
    pts[#pts + 1] = x
    pts[#pts + 1] = y
  end
  local marks = {}
  for _, note in ipairs(notes) do
    local i0, i1 = sampleAt(note.dist), sampleAt(note.endDist)
    local lx, ly = toLocal(viewSamples[i0])
    marks[#marks + 1] = { i0 = i0, i1 = i1, grade = note.grade, kind = note.kind, label = note.short, x = lx, y = ly }
  end
  local brakeMark
  if brake.state ~= 'none' and brake.margin then
    local x, y = toLocal(viewSamples[sampleAt(max(brake.margin, 0))])
    brakeMark = { x = x, y = y, state = brake.state }
  end
  return { pts = pts, marks = marks, brake = brakeMark, speed = speed }
end

local function sendUI()
  local mul, unit = 3.6, 'km/h'
  if settings.getValue('uiUnitLength') == 'imperial' then mul, unit = 2.23694, 'mph' end
  local list = {}
  for _, n in ipairs(notes) do
    if n.dist > -5 and #list < 3 then
      list[#list + 1] = {
        text = n.text, dist = floor(max(n.dist, 0) + 0.5), sign = n.sign or 0, grade = n.grade, kind = n.kind,
        speed = n.vSafe and floor(n.vSafe * mul + 0.5) or nil,
      }
    end
  end
  guihooks.trigger('CoDriverCoachUpdate', {
    enabled = cfg.enabled, voice = cfg.voice, surface = cfg.surface, style = cfg.style, voicepack = cfg.voicepack,
    hasVoice = clipCount > 0, onRoad = onRoad, usingRoute = usingRoute, unit = unit,
    speed = floor(speed * mul + 0.5), notes = list,
    brake = { state = cfg.brakeAid ~= 'off' and brake.state or 'none', target = brake.target and floor(brake.target * mul + 0.5) or nil, text = brake.text,
      -- the bar fills from 3 s before the brake point (empty) to the brake point (full)
      fill = brake.margin and speed > 1 and floor(clamp(1 - brake.margin / (speed * 3), 0, 1) * 100) or nil },
    hint = hint.text, hintLevel = hint.level, shift = shift, lastCall = lastCall,
    view = buildView(),
    drive = drive and { time = floor(drive.time), dist = floor(drive.dist), corners = #drive.corners } or nil,
    recording = coDriverAnalysis and coDriverAnalysis.isRecording() or nil,
    stage = S.stage and { km = S.stage.km, left = floor((core_groundMarkers and core_groundMarkers.getPathLength() or 0) + 0.5) } or nil,
    loading = S.pendingScenario and S.pendingScenario.sc.title or nil,
  })
end

-- The braking line on the road (brakeAid 'zone'): one bar across the whole road where you need to be
-- braking for the next corner, from your speed now (as updateBrake works it out), amber while it is
-- coming and red once you should be braking. It is fixed to the road: on the approach it stays put
-- while the brake point moves less than 2.5 m and glides to it when it moves further (you sped up or
-- lifted), so it doesn't creep with every update of the road ahead; once you are on the brakes (or it
-- says brake now) it locks for that corner, like a board at the roadside. Two prisms a frame; the road
-- width and ground height are looked up only when it moves.
M._drawBrakeZone = function()
  if cfg.brakeAid ~= 'zone' or not cfg.enabled or brake.state == 'none' or not brake.margin or not viewSamples[2] then
    M._brakeLine = nil
    return
  end
  local corner
  for _, note in ipairs(notes) do
    if note.kind == 'corner' and note.text == brake.text and note.dist > -5 then corner = note break end
  end
  local L = M._brakeLine
  local now = os.clock()
  local dt = L and min(now - (L.t or now), 0.1) or 0
  local locked = L and L.locked
  if corner and brake.margin > 0 and not (locked and (L.apex - corner.apexPos):length() <= 15) then
    -- the brake point on the road ahead, between the 4 m samples (not rounded to one)
    local n = #viewSamples
    local x = brake.margin / DS + 1
    local i = clamp(floor(x), 1, n - 1)
    local f = clamp(x - i, 0, 1)
    local a, b = viewSamples[i], viewSamples[i + 1]
    local tx, ty, tz = a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, a.z + (b.z - a.z) * f
    if not L or (L.apex - corner.apexPos):length() > 15 then -- a new corner: the line starts there
      L = { apex = vec3(corner.apexPos), x = tx, y = ty, z = tz, dx = b.x - a.x, dy = b.y - a.y }
      M._brakeLine = L
    else
      local d = sqrt((tx - L.x) ^ 2 + (ty - L.y) ^ 2)
      if d > 2.5 or L.gliding then
        local k = min(1, dt * 6) -- about a third of a second to get there
        L.x, L.y, L.z = L.x + (tx - L.x) * k, L.y + (ty - L.y) * k, L.z + (tz - L.z) * k
        L.dx, L.dy = b.x - a.x, b.y - a.y
        L.gliding = d > 0.5
      end
    end
  end
  if not L then return end
  L.t = now
  if (vehData.brake or 0) > 0.2 or brake.state == 'brake' or brake.state == 'late' then L.locked, L.gliding = true, false end
  -- across the road at that point: from edge to edge, on the ground
  if not L.ends or (L.endsX - L.x) ^ 2 + (L.endsY - L.y) ^ 2 > 0.09 then
    local l = sqrt(L.dx * L.dx + L.dy * L.dy)
    if l < 0.01 then return end
    local nx, ny = -L.dy / l, L.dx / l
    local half = 3.5
    local ok, na, nb = pcall(map.findBestRoad, vec3(L.x, L.y, L.z))
    local nodes = ok and map.getMap().nodes
    if nodes and na and nodes[na] and nodes[nb] then half = clamp(max(nodes[na].radius or 0, nodes[nb].radius or 0), 2.5, 9) end
    local function ground(px, py)
      local d = castRayStatic(vec3(px, py, L.z + 2), vec3(0, 0, -1), 5)
      return vec3(px, py, (d and d < 5 and L.z + 2 - d or L.z - 0.35) + 0.06)
    end
    L.ends = { ground(L.x + nx * half, L.y + ny * half), ground(L.x, L.y), ground(L.x - nx * half, L.y - ny * half) }
    L.endsX, L.endsY = L.x, L.y
  end
  local col = brake.state == 'soon' and ColorF(1, 0.75, 0.2, 0.6) or ColorF(1, 0.25, 0.2, 0.7)
  local w = Point2F(0.03, 0.6)
  debugDrawer:drawSquarePrism(L.ends[1], L.ends[2], w, w, col)
  debugDrawer:drawSquarePrism(L.ends[2], L.ends[3], w, w, col)
end

-- in-car navigation screens -------------------------------------------------------
-- Any car whose current configuration has a navigation screen (beamNavigator controller)
-- shows the coach's map on it: a drawing layer is injected into the screen's own page,
-- so no game files are replaced and the stock navigator shows again when the layer hides.

local onScreens, hideScreens, updateScreens, resetScreens, getScreens
do
  local screenJS = nil
  local screens, screensAskedT, screensAnswered = {}, -100, false
  local screenInstallT, screenTimer = -100, 0
  local framed = false

  -- Where each car's screen bottom edge sits, in degrees below the driver's eye line with no tilt.
  -- Measured by flooding the screen with a marker colour and finding it in driver-view screenshots.
  local SCREEN_BOTTOM = { etk800 = -19.6, vivace = -18.3 } -- vivace: lower of its two screens (ardente -17.9, regular -18.3)
  local DEFAULT_SCREEN_BOTTOM = -20     -- typical centre-console screen, for cars not measured yet
  local TILT_RESPONSE = 0.835           -- view moves ~0.84 deg per degree of seat tilt (pivot behind the eyes)

  -- Tilt the driver camera down just enough that the whole screen fits, keeping as much road as possible.
  local function frameScreen(veh)
    -- 0.40 made the driver camera an occupant camera ('occupant.<seat>' or 'onboard.driver'); the
    -- game's helper finds it in either version
    local drv
    if core_camera.getDriverCameraNameById then drv = select(2, core_camera.getDriverCameraNameById(veh:getId())) end
    if not drv then
      local cams = core_camera.getCameraDataById(veh:getId())
      drv = cams and cams.driver
    end
    if not drv or drv.seatPosition == nil then return end -- driver camera not set up yet for this car
    framed = true
    if drv.seatRotation ~= 0 or drv.seatPosition.y ~= 0 or drv.seatPosition.z ~= 0 then return end -- the user's own seat wins
    local bottom = SCREEN_BOTTOM[veh:getJBeamFilename()] or DEFAULT_SCREEN_BOTTOM
    local fov = tonumber(settings.getValue('cameraDriverFov')) or 55
    local shift = (-fov / 2 + 1.5) - bottom -- degrees the screen must move up to sit 1.5 deg inside the edge
    if shift <= 0 then return end
    drv.seatRotation = -min(shift / TILT_RESPONSE, 15)
    drv.saveTimeout = 0 -- the camera saves it as this car's seat setting
    log('I', logTag, string.format('tilted the driver view %.1f deg to show the screen of %s', drv.seatRotation, veh:getJBeamFilename()))
  end

  local screenQueryCmd = [[local out = {} for _, c in ipairs(v.data.controller or {}) do if c.fileName == "beamNavigator" then out[#out + 1] = c.screenMaterialName or "@screen_gps" end end obj:queueGameEngineLua("if coDriverCoach then coDriverCoach.onScreens(" .. obj:getId() .. "," .. serialize(out) .. ") end")]]

  onScreens = function(id, list)
    if id ~= vehId then return end
    screens, screensAnswered, screenInstallT = type(list) == 'table' and list or {}, true, -100
  end

  local function screenData()
    local view = buildView()
    if not view then return 'null' end
    local mul, unit = 3.6, 'km/h'
    if settings.getValue('uiUnitLength') == 'imperial' then mul, unit = 2.23694, 'mph' end
    local nextNote
    for _, n in ipairs(notes) do
      if n.dist > -5 then nextNote = n; break end
    end
    return jsonEncode({
      v = view, u = unit, b = brake.state,
      n = nextNote and { text = nextNote.text, dist = floor(max(nextNote.dist, 0) + 0.5), grade = nextNote.grade,
        speed = nextNote.vSafe and floor(nextNote.vSafe * mul + 0.5) or nil } or nil,
    })
  end

  local function showOnScreens(veh, js)
    for _, m in ipairs(screens) do veh:queueJSUITexture(m, js) end
  end

  hideScreens = function()
    local veh = getPlayerVehicle(0)
    if veh and screens[1] then showOnScreens(veh, 'window.coDriverView && window.coDriverView(null)') end
  end

  updateScreens = function(veh, dt)
    if not screensAnswered and clock - screensAskedT > 3 then -- ask the car which screens it has
      screensAskedT = clock
      veh:queueLuaCommand(screenQueryCmd)
    end
    if not screens[1] then return end
    if not framed and cfg.consoleMap and cfg.frameScreen then frameScreen(veh) end
    screenTimer = screenTimer - dt
    if screenTimer > 0 then return end
    screenTimer = 0.2
    if cfg.consoleMap and clock - screenInstallT > 5 then -- (re)install the layer; it ignores repeats
      screenJS = screenJS or readFile('/lua/ge/extensions/coDriverCoach_screen.js')
      if screenJS then showOnScreens(veh, screenJS) end
      screenInstallT = clock
    end
    showOnScreens(veh, 'window.coDriverView && window.coDriverView(' .. (cfg.consoleMap and screenData() or 'null') .. ')')
  end

    resetScreens = function()
      screens, screensAnswered, screensAskedT, screenInstallT, framed = {}, false, clock - 2, -100, false
    end
    getScreens = function() return screens end

end

-- main loop ----------------------------------------------------------------------

local function resetVehicle(id)
  if drive then endDrive(false) end
  saveCarProfile()
  resetScreens()
  vehId, lastVel, vehData = id, nil, {}
  speed, latAcc, lonAcc, slip, jerk, jerkLat, lastG, lastDamage = 0, 0, 0, 0, 0, 0, nil, nil
  latSus, decelSus = 0, 0
  loadCarProfile(id and getObjectByID(id))
  steerGain, steerGainCount = {}, {}
  notes, called, brakeCalled, brakeNowCalled = {}, {}, {}, {}
  hint = { text = nil, level = 0, untilT = 0 }
end

local function updateNotes(veh)
  local pos = vec3(veh:getPosition())
  local dir = vec3(veh:getDirectionVector())
  local decel = brakeG() * G
  local horizon = clamp(speed * cfg.callAheadSec + 160 + speed * speed / (2 * decel), 220, 900)
  local pts = routeAhead(pos, horizon, dir)
  usingRoute = pts ~= nil
  pts = pts or graphAhead(pos, dir, horizon)
  onRoad = pts ~= nil and #pts >= 2
  local samples = onRoad and resample(pts) or {}
  pathInfo = { nodes = pts and #pts or 0, samples = #samples, length = #samples * DS, horizon = horizon }
  viewSamples, viewPos, viewDir = samples, pos, dir
  notes = onRoad and analyzePath(samples) or {}

  -- off-road check against the nearest road's width; far from any road counts as free driving
  local nodes = map.getMap().nodes
  local ok, a, b, d = pcall(map.findBestRoad, pos, dir)
  if ok and a and nodes[a] and nodes[b] and d then
    roadNear = d < 30
    offRoad = roadNear and d > max(nodes[a].radius or 3, nodes[b].radius or 3) + 0.75
  else
    roadNear, offRoad = false, false
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  clock = clock + dtReal
  updateScenario()
  if not cfg.enabled then return end
  if core_replay.getState() == 'playback' then return end -- reviewing a replay: no calls on the replayed car
  updateVoice()

  local veh = getPlayerVehicle(0)
  if not veh then return end
  local id = veh:getId()
  if id ~= vehId then resetVehicle(id) end

  local vel = vec3(veh:getVelocity())
  if vel:length() > 150 then -- a reset or teleport frame, not real motion
    lastVel, dtSim = nil, 0
  end
  if dtSim > 0 then
    updateDynamics(dtSim, vel, vec3(veh:getDirectionVector()))
    if cfg.carControl then updateCarControl(dtSim) end
    updateDriveMetrics(dtSim)
  end

  vehTimer = vehTimer - dtReal
  if vehTimer <= 0 then
    vehTimer = 0.1
    veh:queueLuaCommand(vehDataCmd)
  end

  pathTimer = pathTimer - dtReal
  if pathTimer <= 0 then
    pathTimer = 0.1
    local ok, err = pcall(function()
      updateNotes(veh)
      trackCorners()
      callNotes()
      updateBrake()
      updateShift()
    end)
    if not ok and not errorLogged.update then
      errorLogged.update = true
      log('E', logTag, 'update failed: ' .. tostring(err))
    end
  end

  uiTimer = uiTimer - dtReal
  if uiTimer <= 0 then
    uiTimer = 0.1
    sendUI()
  end

  local okScreens, errScreens = pcall(updateScreens, veh, dtReal)
  if not okScreens and not errorLogged.screens then
    errorLogged.screens = true
    log('E', logTag, 'screen update failed: ' .. tostring(errScreens))
  end
end

-- commands (UI app, hotkeys, console) --------------------------------------------

local function setEnabled(v)
  cfg.enabled = v and true or false
  if not cfg.enabled then hideScreens() end
  voiceQueue, notes = {}, {}
  saveSettings()
  if cfg.chatter then
    if cfg.enabled then say(list(pick('coach_on'))) else playNow('coach_off') end
  end
  sendUI()
end

local function toggle() setEnabled(not cfg.enabled) end

local function toggleVoice()
  cfg.voice = not cfg.voice
  if not cfg.voice then voiceQueue = {} end
  saveSettings()
  sendUI()
end

-- learned grip is kept per surface, so switch profiles along with the surface
local function setSurface(name, silent)
  if not surfaces[name] then return end
  saveCarProfile()
  cfg.surface = name
  loadCarProfile(getPlayerVehicle(0))
  saveSettings()
  if not silent and cfg.chatter then say(list(pick('surface_' .. name))) end
  sendUI()
end

local function cycleSurface()
  for i, s in ipairs(surfaceOrder) do
    if s == cfg.surface then return setSurface(surfaceOrder[i % #surfaceOrder + 1]) end
  end
end

local function toggleStyle()
  cfg.style = cfg.style == 'numbers' and 'words' or 'numbers'
  saveSettings()
  sendUI()
end

local function cycleVoicepack()
  scanVoicepacks()
  local start = 1
  for i, name in ipairs(voicepacks) do
    if name == cfg.voicepack then start = i end
  end
  for step = 1, #voicepacks do
    local name = voicepacks[(start + step - 1) % #voicepacks + 1]
    if loadVoicepack(name) then
      cfg.voicepack = name
      break
    end
  end
  saveSettings()
  say({ 'caution' })
  sendUI()
end

-- Switch to a voicepack by folder name, e.g. 'custom'. Returns true if it loaded.
local function setVoicepack(name)
  if not loadVoicepack(tostring(name)) then return false end
  cfg.voicepack = tostring(name)
  saveSettings()
  say({ 'three_left', 'tightens' })
  sendUI()
  return true
end

local function setCallAhead(sec)
  cfg.callAheadSec = clamp(tonumber(sec) or defaults.callAheadSec, 2, 8)
  saveSettings()
end

local function setOption(key, value)
  if defaults[key] == nil or type(value) ~= type(defaults[key]) then return end
  if key == 'brakeAid' and not ({ off = true, bar = true, zone = true })[value] then return end
  if key == 'voiceOutput' and value ~= 'plain' and value ~= 'intercom' then return end
  if key == 'style' and value ~= 'numbers' and value ~= 'words' then return end
  if key == 'callAheadSec' then value = clamp(value, 2, 8) end
  if key == 'voiceVolume' then value = clamp(value, 0.2, 3) end
  cfg[key] = value
  saveSettings()
  sendUI()
end

-- scenarios (lua/ge/extensions/coDriverCoach/scenarios.lua) ----------------------------------
package.loaded['coDriverCoach/scenarios'] = nil -- reloading the coach picks up a new copy
local scen = require('coDriverCoach/scenarios').new({
  cfg = cfg, logTag = logTag, clock = function() return clock end, drive = function() return drive end,
  say = function(...) return say(...) end, sayAt = function(...) return sayAt(...) end,
  pick = function(...) return pick(...) end, list = function(...) return list(...) end,
  sendUI = function(...) return sendUI(...) end, setSurface = function(...) return setSurface(...) end,
  endDrive = function(...) return endDrive(...) end, saveSettings = function(...) return saveSettings(...) end,
}, S)
updateScenario = scen.update

package.loaded['coDriverCoach/recce'] = nil
recce = require('coDriverCoach/recce').new({
  cfg = cfg, say = function(...) return say(...) end, announce = function(...) return announce(...) end,
  log = function(level, msg) log(level, logTag, msg) end, notify = function(msg) guihooks.message(msg, 6, 'coDriverCoach') end,
})

-- Everything the coach currently sees, for debugging from the console or MCP.
local function getDebugState()
  local list = {}
  for _, n in ipairs(notes) do
    list[#list + 1] = {
      kind = n.kind, text = n.text, dist = n.dist, endDist = n.endDist, R = n.R, Reff = n.Reff,
      angleDeg = n.angleDeg, vSafe = n.vSafe, complete = n.complete,
    }
  end
  return {
    enabled = cfg.enabled, cfg = cfg, voicepack = cfg.voicepack, clipCount = clipCount,
    onRoad = onRoad, usingRoute = usingRoute, path = pathInfo, speed = speed, latG = latAcc / G, slipDeg = slip * 180 / pi,
    vehData = vehData, notes = list, brake = brake, hint = hint.text, shift = shift, calls = callLog,
    screens = getScreens(), jerk = jerk, offRoad = offRoad, roadNear = roadNear, learned = learned, carKey = carKey, gripG = gripG(), brakeG = brakeG(),
    drive = drive and {
      time = drive.time, dist = drive.dist, corners = #drive.corners, brakeCues = drive.brakeCues, brakeMissed = drive.brakeMissed,
      brakeLate = drive.brakeLate, brakeSlow = drive.brakeSlow, oversteer = drive.oversteer, bigSlide = drive.bigSlide,
      understeer = drive.understeer, meanJerk = drive.jerkTime > 0 and drive.jerkSum / drive.jerkTime or 0, harsh = drive.harsh,
      offRoadTime = drive.offRoadTime, roadTime = drive.roadTime, crashes = drive.crashes, resets = drive.resets,
    } or nil,
  }
end

local function requestState()
  sendUI()
  sendSummary()
  scen.sendMenu()
end

local function endDriveNow() endDrive(true) end

-- Show a debrief built from made-up numbers (not saved to history), to check the panel.
local function testSummary()
  local d = newDrive()
  d.time, d.dist, d.maxSpeed = 245, 3900, 36
  for i = 1, 18 do
    d.corners[i] = { text = (i % 6 + 1) .. (i % 2 == 0 and ' Left' or ' Right'), vSafe = 18, grade = 3,
      minSpeed = i <= 3 and 23 or 15.5, incident = i <= 3 }
  end
  d.brakeCues, d.brakeMissed, d.brakeLate, d.brakeSlow = 9, 1, 2, 1
  d.oversteer, d.understeer = 2, 1
  d.jerkSum, d.jerkLatSum, d.jerkTime, d.harsh = 7.5 * 230, 4 * 230, 230, 6
  d.pedalTime, d.pedalAnalog = 150, 90
  d.roadTime, d.offRoadTime, d.crashes = 240, 4, 1
  summary = buildSummary(d, true)
  sendSummary()
  return summary
end

local function dismissSummary()
  summary = nil
  sendSummary()
end

local function onExtensionLoaded()
  loadSettings()
  ensureVoicepack()
  log('I', logTag, 'loaded; voicepack ' .. tostring(cfg.voicepack) .. ' (' .. clipCount .. ' clips)')
end

local function onVehicleSwitched(oldId, newId)
  resetVehicle(newId)
end

local function onVehicleResetted(id)
  if id ~= vehId then return end
  if cfg.chatter and not S.pendingScenario then say(list(pick('reset'))) end
  lastImpactT, lastDamage = clock, nil
  if drive then
    drive.resets = drive.resets + 1
    drive.incidents = drive.incidents + 1
    drive.damageBase = nil
    drive.pendingBrake = nil
    table.insert(drive.impacts, clock)
    trackedCorners = {}
  end
end

local function onClientEndMission()
  endDrive(false) -- grades a drive in progress and saves the learned grip either way
  vehId, S.stage = nil, nil
end

M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleResetted = onVehicleResetted
M.onClientEndMission = onClientEndMission
M.onClientPostStartMission = scen.onClientPostStartMission
M.onVehicleData = onVehicleData
M.onScreens = onScreens
M.endDrive = endDriveNow
M.dismissSummary = dismissSummary
M.getSummary = function() return summary end
M.testSummary = testSummary
M.loadScenario = scen.loadScenario
M.restartScenario = scen.restartScenario
M.cancelStage = scen.cancelStage
M.openMenu = scen.openMenu
M.closeMenu = scen.closeMenu
M.toggleMenu = scen.toggleMenu
M._scenarios = scen -- for tests and the console

M.toggle = toggle
M.setEnabled = setEnabled
M.toggleVoice = toggleVoice
M.cycleSurface = cycleSurface
M.setSurface = setSurface
M.toggleStyle = toggleStyle
M.cycleVoicepack = cycleVoicepack
M.setVoicepack = setVoicepack
M.setCallAhead = setCallAhead
M.setOption = setOption
M.onPreRender = function() if M._drawBrakeZone then pcall(M._drawBrakeZone) end end
-- for the settings panel: every option, the voicepacks found, and what grip the targets use
M.getSettings = function()
  local c = {}
  for k, v in pairs(cfg) do c[k] = v end
  if #voicepacks == 0 then pcall(scanVoicepacks) end
  local packs = {}
  for i, name in ipairs(voicepacks) do packs[i] = name end
  return { cfg = c, voicepacks = packs, grip = { lat = gripG(), brake = brakeG(), corners = #(learned.latPeaks or {}), legacy = learned.legacy or nil, car = carKey } }
end
M.requestState = requestState
M.say = say
M.recceArm = function(on, route) return recce.arm(on, route) end
M.recceClear = function(level, route) return recce.clear(level or getCurrentLevelIdentifier(), route) end
M.recceInfo = function(level, routes) return recce.info(level, routes) end
M.recceState = function() return recce.state() end
M.voiceWords = function() -- the voicepack's phrases, for the engineer's lines in your voice
  local out = {}
  for k in pairs(clips) do out[#out + 1] = k end
  table.sort(out)
  return out
end
-- Say a short line in the voicepack's own voice if every word of it is recorded: greedy longest match
-- of the words to the clip names ("nice save" -> nice_save, "brake hard now" -> brake_hard + ...).
-- Returns true when it was queued, false when a word is missing (the caller uses another voice).
M.sayPhrase = function(text)
  local words = {}
  for w in tostring(text or ''):lower():gsub("'", ''):gmatch('[%w]+') do words[#words + 1] = w end
  -- the voice only plays while the coach runs (not off, not during a replay)
  if not words[1] or not cfg.voice or not cfg.enabled or core_replay.getState() == 'playback' then return false end
  local out, i = {}, 1
  while i <= #words do
    local found
    for j = min(#words, i + 3), i, -1 do
      local key = table.concat(words, '_', i, j)
      if clips[key] then found = j out[#out + 1] = key break end
    end
    if not found then return false end
    i = found + 1
  end
  say(out)
  return true
end
M.getDebugState = getDebugState
-- for the engineer's event list: corners finished after index `from`, and the crash and reset counts
M.getDriveEvents = function(from)
  if not drive then return nil end
  local out = {}
  for i = (from or 0) + 1, #drive.corners do
    local c = drive.corners[i]
    out[#out + 1] = { text = c.text, minSpeed = c.minSpeed, vSafe = c.vSafe, incident = c.incident }
  end
  return { corners = out, n = #drive.corners, crashes = drive.crashes, resets = drive.resets }
end
M.getView = buildView
M.isStageActive = function() return S.stage ~= nil end
M.isEnabled = function() return cfg.enabled end
M.getGrip = function() return gripG(), brakeG() end
-- forget what was learned for the current car and surface (back to surface defaults)
M.resetLearnedGrip = function()
  learned = {}
  if carKey then
    local cars = loadCars()
    cars[carKey] = nil
    jsonWriteFile(carsPath, cars, true)
  end
  return carKey
end

return M
