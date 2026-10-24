-- Co-Driver Coach: post-drive analysis, the "race engineer" review.
-- While you drive it records about 60 Hz of telemetry (vehicle extension coDriverRec) and a quiet
-- game replay. Afterwards it builds a theoretical better line (minimum curvature within the road
-- edges and the walls found by raycasts), an ideal speed profile from a model of the car (grip
-- you showed, aero, power, brakes, surface) aimed at a share of the limit, compares both with
-- what you did, ranks the corners by time lost and can replay each one with both lines in 3D.
-- Method notes: docs/ANALYSIS_DESIGN.md.
local M = {}
local logTag = 'coDriverAnalysis'
local G = 9.81
local abs, sqrt, min, max, floor, huge = math.abs, math.sqrt, math.min, math.max, math.floor, math.huge

local DS = 4                         -- analysis grid spacing (m)
local REPLAY_DIR = 'replays/codriver/'
-- Replay files (about 55 MB a minute) are never deleted automatically: the user's recordings
-- are only removed by the user. A file ends when recording pauses (parked, or the replay mode
-- stops wanting it); timed rotation is off (nil) and only used by tests (setReplayPartSecs).
local PART_SECS = nil
local SAVE_PATH = 'settings/coDriverCoach/last_session.json'
local OPTIONS_PATH = 'settings/coDriverCoach/analysis_settings.json'
local SESS_DIR = 'settings/coDriverCoach/sessions/' -- archive of past sessions (telemetry only)
local SESS_INDEX = SESS_DIR .. 'index.json'
local SESS_MIN_SECS, SESS_MIN_M = 60, 500 -- sessions shorter than this are not archived
local DAMAGED_PATH = 'settings/coDriverCoach/damaged_replays.json' -- replay files that failed to play
local MAX_SAMPLES = 60 * 60 * 45     -- 45 minutes at 60 Hz
local SAMPLE_FMT = 2                 -- 1: 20 Hz, 17 fields; 2: 60 Hz with load and surface
local TRACE_DS, TRACE_DT = 0.5, 0.1  -- chart traces keep a raw sample every 0.5 m or 0.1 s
local RAY_UP = { 0.6, 1.2 }          -- wall rays: heights above the ground
local REF_UP = 0.35                  -- the car's reference point sits about this high
local RAY_MAX = 25

-- sample fields, as sent by coDriverRec
local T, X, Y, Z, VX, VY, VZ, DX, DY, THR, BRK, STR, GEAR, RPM, ABS, BP, WS = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17
local LOAD, SURF = 18, 19            -- tyre load / weight, surface class (format 2)
local LON, LAT, SPD = 20, 21, 22     -- added during analysis
local TLON, NF = 23, 24              -- the tyres' share of LON (gravity on slopes removed), vertical load factor

-- surface classes from coDriverRec, with grip relative to dry tarmac when there is too little
-- driving on one to measure it
local SURF_NAME = { [1] = 'tarmac', [2] = 'wet tarmac', [3] = 'gravel', [4] = 'grass', [5] = 'snow' }
local SURF_GRIP = { [1] = 1, [2] = 0.8, [3] = 0.72, [4] = 0.55, [5] = 0.35 }
local CIRCUITS = { hirochi_raceway = true, automation_test_track = true }

-- what the model aims for, and how strict the rules are, per driving style
local STYLE = {
  circuit = { edge = 0.2, wall = 0.3, brakeM = 8, brakeShare = 0.1, wide = 0.8, coast = 0.3 },
  rally = { edge = 0.5, wall = 0.5, brakeM = 15, brakeShare = 0.15, wide = 1.5, coast = 0.5 },
}
local REPLAY_MODES = { off = true, laps = true, always = true }
local options = { margin = 0.95, style = 'auto', recordReplay = 'laps' } -- margin: share of the limit the better line uses

local rec = nil          -- session being recorded
local lastSession = nil  -- session being reviewed (the last one, or one opened from the archive)
local saveSession        -- defined with the archive below
local result = nil       -- analysis of lastSession
local panelOpen = false
local replay = nil       -- replay playback state
local clock, chunkT, stateTimer, movingT = 0, 0, 0, 0

local function clamp(x, a, b) return x < a and a or (x > b and b or x) end
local function round(x, d) local m = 10 ^ (d or 0) return floor(x * m + 0.5) / m end

local function percentile(arr, p)
  if #arr == 0 then return nil end
  local c = {}
  for i = 1, #arr do c[i] = arr[i] end
  table.sort(c)
  return c[clamp(floor(#c * p) + 1, 1, #c)]
end

local function coachEnabled()
  return coDriverCoach and coDriverCoach.isEnabled and coDriverCoach.isEnabled()
end

local function inForeignReplay()
  return not replay and core_replay and core_replay.getState and core_replay.getState() == 'playback'
end

-- recording ---------------------------------------------------------------------

local function ourRecordingRunning()
  if not core_replay or core_replay.getState() ~= 'recording' then return false end
  local loaded = tostring(core_replay.state and core_replay.state.loadedFile or ''):gsub('^/', '')
  return loaded:find(REPLAY_DIR, 1, true) == 1
end

local readIndex -- the session archive's index, defined with the archive below

-- Replay files are never deleted by the mod (the user deletes recordings). This only counts
-- what is in the folder, for the panel.
local function replayUsage()
  local files = FS:findFiles(REPLAY_DIR, '*.rpl', 0, false, false) or {}
  return #files
end

-- Starts a new replay file for the session, beginning at session time t0.
local function startReplayPart(t0)
  if not core_replay then return nil end
  if core_replay.getState() ~= 'inactive' then return nil end
  if not FS:directoryExists(REPLAY_DIR) then FS:directoryCreate(REPLAY_DIR, true) end
  local fn = REPLAY_DIR .. 'drive_' .. os.date('%Y%m%d_%H%M%S') .. '.rpl'
  local ok, err = pcall(function() be:getFileStream():record(fn) end)
  if not ok then
    log('W', logTag, 'replay recording not started: ' .. tostring(err))
    return nil
  end
  local part = { file = fn, t0 = t0, gameVersion = rawget(_G, 'beamng_versiond') }
  table.insert(rec.parts, part)
  rec.replayFile = fn
  return part
end

-- Stops our recording. The stream finishes writing the file after this frame, so nothing may
-- start recording again until it reports 'inactive' (see updateReplayParts): starting the next
-- file in the same frame left the old one without its last packet, and it would not play.
local function stopReplayRecording()
  if ourRecordingRunning() then
    pcall(function() be:getFileStream():stop() end)
    if rec then rec.replayStopT = clock end
  end
  if rec then rec.replayFile = nil end
end

-- Whether the replay recorder should run now. 'laps' records only timed runs: a lap on a
-- recognised route (coDriverLaps, from just before its start line), a scenario GPS stage in
-- progress, or a drive the user armed by hand (panel button or hotkey). Telemetry is recorded either way.
local function wantReplay()
  local mode = options.recordReplay
  if mode == 'always' then return true end
  if mode ~= 'laps' or not rec then return false end
  if rec.armed then return true end
  if coDriverLaps and coDriverLaps.wantsReplay and coDriverLaps.wantsReplay() then return true end
  local ok, stageOn = pcall(function() return coDriverCoach and coDriverCoach.isStageActive and coDriverCoach.isStageActive() end)
  return ok and stageOn == true
end

local function lastSampleT(sess)
  local s = sess and sess.samples[#sess.samples]
  return s and s[T] or 0
end

-- Start and stop the replay recorder: only while the mode wants it, paused while parked (it
-- grows by about 55 MB a minute even then). A stopped file is finished by the stream in the
-- following frames, so nothing starts again until it reports 'inactive'.
local function updateReplayParts(dt, speed)
  local part = rec.parts[#rec.parts]
  local now = lastSampleT(rec)
  rec.stillT = speed < 0.5 and (rec.stillT or 0) + dt or 0
  local want = wantReplay()
  -- a few seconds of not wanting it before stopping: after a teleport the lap tracker needs a
  -- moment to find the car's direction again, and stopping at once left a 3 s file
  rec.wantOffT = want and 0 or (rec.wantOffT or 0) + dt
  local settling = false
  if rec.replayStopT then -- a file we stopped is still being finished
    if core_replay.getState() == 'inactive' and clock - rec.replayStopT > 0.5 then
      rec.replayStopT = nil
    elseif clock - rec.replayStopT > 5 then
      log('W', logTag, 'replay stream did not stop; replay recording paused for this session')
      rec.replayStopT, rec.replayBlocked = nil, true
    else
      settling = true
    end
  end
  if settling then
    -- wait
  elseif rec.replayFile and ((not want and rec.wantOffT > 5) or rec.stillT > 90) then
    stopReplayRecording()
  elseif not rec.replayFile and want and (speed > 2 or rec.rotating) and not rec.replayBlocked then
    rec.rotating = nil
    if not startReplayPart(now) then rec.replayBlocked = true end -- someone else is using the recorder
  elseif PART_SECS and part and rec.replayFile and now - part.t0 >= PART_SECS then
    stopReplayRecording()
    rec.rotating = true -- tests only: the next part starts once the stream has finished this one
  end
end

-- Game versions: BeamNG 0.40 refuses replays recorded by an older version. New replay parts carry
-- the game version; for parts from before that, the first time this mod ran under the current
-- version (settings/coDriverCoach/game_versions.json) tells which files are older.
local VERSIONS_PATH = 'settings/coDriverCoach/game_versions.json'
local versionsSeen = nil
local function majorMinor(v) return tostring(v or ''):match('^(%d+%.%d+)') end
local function noteGameVersion()
  local cur = majorMinor(rawget(_G, 'beamng_versiond'))
  if not cur then return end
  versionsSeen = FS:fileExists(VERSIONS_PATH) and jsonReadFile(VERSIONS_PATH)
  if type(versionsSeen) ~= 'table' then versionsSeen = {} end
  if not versionsSeen[cur] then
    versionsSeen[cur] = os.time()
    pcall(jsonWriteFile, VERSIONS_PATH, versionsSeen, true)
  end
end
-- false for a replay recorded by another game version (it won't play); mt: the file's modtime if known
local function versionOk(gameVersion, mt)
  local cur = majorMinor(rawget(_G, 'beamng_versiond'))
  if not cur then return true end
  if gameVersion then return majorMinor(gameVersion) == cur end
  local since = versionsSeen and versionsSeen[cur]
  return not (since and mt and mt < since - 60)
end
local function fileModTime(file)
  local ok, st = pcall(function() return FS:stat(file) end)
  return ok and type(st) == 'table' and st.modtime or nil
end
local function partVersionOk(part)
  return not part or versionOk(part.gameVersion, not part.gameVersion and fileModTime(part.file) or nil)
end

-- Replay files that failed to load are remembered, so they are skipped instead of retried
-- (true: damaged; 'version': recorded by a game version that can't play here).
local damaged = nil
local function isDamaged(file)
  if not damaged then
    damaged = FS:fileExists(DAMAGED_PATH) and jsonReadFile(DAMAGED_PATH)
    if type(damaged) ~= 'table' then damaged = {} end
  end
  local d = damaged[tostring(file):lower()]
  return d ~= nil and d ~= false
end
local function markDamaged(file, reason)
  isDamaged(file)
  damaged[tostring(file):lower()] = reason or true
  pcall(jsonWriteFile, DAMAGED_PATH, damaged, true)
end
local function partOk(part) return part and FS:fileExists(part.file) and not isDamaged(part.file) and partVersionOk(part) end

-- The replay part holding session time t, if it can be played.
local function findPart(sess, t)
  local found
  for _, part in ipairs(sess and sess.parts or {}) do
    if part.t0 <= t + 0.5 then found = part end
  end
  if partOk(found) then return found end
end

local function startSession(veh)
  rec = {
    vid = veh:getId(), samples = {}, simT = 0, date = os.date('%Y-%m-%d %H:%M'), stamp = os.date('%Y%m%d_%H%M%S'),
    level = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or '',
    model = select(2, pcall(function() return veh:getJBeamFilename() end)), lastVehT = -1, vehOffset = 0, dist = 0,
    parts = {}, fmt = SAMPLE_FMT,
    car = { halfWidth = select(2, pcall(function() return veh:getInitialWidth() / 2 end)) },
  }
  veh:queueLuaCommand('extensions.load("coDriverRec") if coDriverRec then coDriverRec.start() end')
  if ourRecordingRunning() then
    stopReplayRecording() -- ours, left running by an earlier load of this extension; restarts when finished
  elseif wantReplay() and not startReplayPart(0) then
    rec.replayBlocked = true
  end
  chunkT = clock
  log('I', logTag, 'recording started' .. (rec.replayFile and (' with replay ' .. rec.replayFile) or ' (telemetry only)'))
end

-- Ends the recording; the session is kept for analysis and saved (last session + archive),
-- whether it ends with a review or not (car switch, level end, coach off, unload).
local function endSession()
  if not rec then return lastSession end
  if rec.pendingBest and M._flushBest then pcall(M._flushBest, true) end
  local veh = be:getObjectByID(rec.vid)
  if veh then veh:queueLuaCommand('if coDriverRec then coDriverRec.stop() end') end
  stopReplayRecording()
  local sess = rec
  rec = nil
  if #sess.samples > 0 then
    lastSession = sess
    saveSession(sess)
  end
  return lastSession
end

-- Batches from coDriverRec. Vehicle time restarts if the car is reloaded; keep ours monotonic.
local function onChunk(id, list)
  if not rec or id ~= rec.vid or type(list) ~= 'table' then return end
  chunkT = clock
  local s = rec.samples
  for _, smp in ipairs(list) do
    if smp[T] < rec.lastVehT then rec.vehOffset = (s[#s] and s[#s][T] or 0) + 0.02 - smp[T] end
    rec.lastVehT = smp[T]
    smp[T] = smp[T] + rec.vehOffset
    local prev = s[#s]
    if prev then
      local d = sqrt((smp[X] - prev[X]) ^ 2 + (smp[Y] - prev[Y]) ^ 2)
      if d < 30 then rec.dist = rec.dist + d end
    end
    s[#s + 1] = smp
  end
  -- lap timing clock against ours (a batch ends with the newest sample), for lap times on the timeline
  if coDriverLaps and coDriverLaps.getClock and s[#s] then
    local off = s[#s][T] - coDriverLaps.getClock()
    rec.lapOff = rec.lapOff and abs(off - rec.lapOff) < 2 and rec.lapOff * 0.9 + off * 0.1 or off
  end
  -- replay clock against ours (for seeking later), smoothed over many batches
  local st = rec.replayFile and core_replay and core_replay.state
  local part = rec.parts[#rec.parts]
  if part and st and st.state == 'recording' and s[#s] and (st.positionSeconds or 0) > 0 then
    local off = st.positionSeconds - s[#s][T]
    part.offset = part.offset and part.offset * 0.9 + off * 0.1 or off
  end
  -- past the limit the oldest 5 minutes go at once (shifting every batch cost a few ms each time)
  if rec.pendingBest and M._flushBest then M._flushBest(false) end
  if #s > MAX_SAMPLES then
    local n = #s
    local drop = n - MAX_SAMPLES + 60 * 60 * 5
    for i = 1, n - drop do s[i] = s[i + drop] end
    for i = n - drop + 1, n do s[i] = nil end
  end
end

-- Car facts from coDriverRec (mass, power, brakes, driven wheels, ABS), sent once per start.
local function onCarInfo(id, info)
  if not rec or id ~= rec.vid or type(info) ~= 'table' then return end
  for k, v in pairs(info) do rec.car[k] = v end
end

-- analysis: driven path to a 4 m grid ---------------------------------------------

-- Split into continuous pieces: teleports, data gaps and stops of 5 s or more break a piece.
local function splitSegments(samples)
  local segs, cur, stopT = {}, {}, 0
  for i, s in ipairs(samples) do
    local prev = samples[i - 1]
    local brk = false
    if prev then
      local dt = s[T] - prev[T]
      local d = sqrt((s[X] - prev[X]) ^ 2 + (s[Y] - prev[Y]) ^ 2)
      if dt > 1.5 or dt <= 0 or d > max(20, 4 * sqrt(s[VX] ^ 2 + s[VY] ^ 2) * dt + 5) then brk = true end
    end
    local v = sqrt(s[VX] ^ 2 + s[VY] ^ 2 + s[VZ] ^ 2)
    s[SPD] = v
    stopT = v < 1 and (prev and stopT + (s[T] - prev[T]) or 0) or 0
    if stopT > 5 then brk = true end
    if brk then
      if #cur > 0 then segs[#segs + 1] = cur end
      cur = {}
    end
    if not (stopT > 5) then cur[#cur + 1] = s end
  end
  if #cur > 0 then segs[#segs + 1] = cur end
  return segs
end

-- Longitudinal and lateral acceleration from velocity differences over 0.2 s, along and across
-- the direction of travel (in a slide the car's heading is not where it's going; the speed
-- model works on the path, so the split is made on the path too).
local function addAccelerations(seg)
  local n = #seg
  local ia, ib = 1, 1
  for i = 1, n do
    local s = seg[i]
    local ti = s[T]
    while ia < i and seg[ia][T] < ti - 0.1 do ia = ia + 1 end
    if ib < i then ib = i end
    while ib < n and seg[ib + 1][T] <= ti + 0.1 do ib = ib + 1 end
    local a, b = seg[ia], seg[ib]
    local dt = b[T] - a[T]
    local ax, ay, az = 0, 0, 0
    if dt > 0.01 then ax, ay, az = (b[VX] - a[VX]) / dt, (b[VY] - a[VY]) / dt, (b[VZ] - a[VZ]) / dt end
    local hx, hy = s[VX], s[VY]
    local hl = sqrt(hx * hx + hy * hy)
    if hl < 3 then hx, hy, hl = s[DX], s[DY], sqrt(s[DX] ^ 2 + s[DY] ^ 2) end
    if hl > 0.1 then hx, hy = hx / hl, hy / hl else hx, hy = 1, 0 end
    s[LON] = ax * hx + ay * hy
    s[LAT] = ax * hy - ay * hx -- positive = to the right
    -- on a slope gravity adds to what the tyres do: uphill it slows you for free, downhill it pushes
    local v3 = sqrt(s[VX] ^ 2 + s[VY] ^ 2 + s[VZ] ^ 2)
    local grade = v3 > 3 and clamp(s[VZ] / v3, -0.35, 0.35) or 0
    s[TLON] = s[LON] + G * grade
    -- vertical load: above 1 in compressions, below 1 over crests (grip scales with it)
    s[NF] = clamp(1 + az / G, 0.2, 2.5)
  end
end

-- Resample by driven distance. Returns columns indexed 1..n; seg.dist keeps each raw sample's distance.
local function toGrid(seg)
  local dist = { 0 }
  for i = 2, #seg do
    local a, b = seg[i - 1], seg[i]
    dist[i] = dist[i - 1] + sqrt((b[X] - a[X]) ^ 2 + (b[Y] - a[Y]) ^ 2 + (b[Z] - a[Z]) ^ 2)
  end
  seg.dist = dist
  local g = { n = 0, x = {}, y = {}, z = {}, t = {}, v = {}, thr = {}, brk = {}, str = {}, gear = {}, rpm = {},
    bp = {}, abs = {}, lon = {}, lat = {}, hx = {}, hy = {}, surf = {}, sampleIdx = {} }
  local j = 1
  local total = dist[#dist]
  local k = 0
  for d = 0, total, DS do
    while j < #seg - 1 and dist[j + 1] < d do j = j + 1 end
    local a, b = seg[j], seg[min(j + 1, #seg)]
    local span = dist[min(j + 1, #seg)] - dist[j]
    local f = span > 1e-6 and clamp((d - dist[j]) / span, 0, 1) or 0
    local function lerp(fld) return a[fld] + (b[fld] - a[fld]) * f end
    k = k + 1
    g.x[k], g.y[k], g.z[k], g.t[k] = lerp(X), lerp(Y), lerp(Z), lerp(T)
    g.v[k], g.thr[k], g.brk[k], g.str[k] = lerp(SPD), lerp(THR), lerp(BRK), lerp(STR)
    g.rpm[k], g.bp[k], g.lon[k], g.lat[k] = lerp(RPM), lerp(BP), lerp(LON), lerp(LAT)
    g.gear[k] = f < 0.5 and a[GEAR] or b[GEAR]
    g.abs[k] = max(a[ABS], b[ABS])
    g.hx[k], g.hy[k] = lerp(DX), lerp(DY)
    g.surf[k] = a[SURF] or 0
    g.sampleIdx[k] = j
  end
  g.n = k
  return g
end

-- Ground height under (x, y), from a short ray down; zGuess is the car's reference height nearby.
local function groundZ(x, y, zGuess)
  local d = castRayStatic(vec3(x, y, zGuess + 1.5), vec3(0, 0, -1), 4)
  return (d and d < 4) and zGuess + 1.5 - d or zGuess - REF_UP
end

-- Distance to static geometry (walls, barriers, banks, trees) to one side of grid point k, from
-- your position: rays at two heights that follow the road's crossfall, so camber or banking
-- doesn't count as a wall. Returns the shorter of the two.
local function rayDist(g, k, side, maxDist)
  local nx, ny = g.nx[k] * side, g.ny[k] * side
  local x, y, z = g.x[k], g.y[k], g.z[k]
  local z0 = groundZ(x, y, z)
  local z1 = groundZ(x + nx * 1.5, y + ny * 1.5, z)
  local slope = clamp((z1 - z0) / 1.5, -0.35, 0.35)
  local dir = vec3(nx, ny, slope):normalized()
  local best = maxDist
  for _, up in ipairs(RAY_UP) do
    local d = castRayStatic(vec3(x, y, z0 + up), dir, maxDist)
    if d and d < best then best = d end
  end
  return best * sqrt(1 - dir.z * dir.z) -- as a horizontal distance
end

-- True when a car of half width `half` driving straight between two points (at ground height)
-- would hit static geometry: low rays across its width about 0.3 m apart (posts and trees), and
-- a high one along its centre.
local function segmentBlocked(ax, ay, az, bx, by, bz, half)
  local dx, dy, dz = bx - ax, by - ay, bz - az
  local len = sqrt(dx * dx + dy * dy + dz * dz)
  if len < 0.05 then return false end
  local dir = vec3(dx / len, dy / len, dz / len)
  local hl = sqrt(dx * dx + dy * dy)
  local nx, ny = hl > 1e-6 and -dy / hl or 0, hl > 1e-6 and dx / hl or 0
  local lanes = half > 0 and math.ceil(2 * half / 0.3) or 0
  for l = 0, lanes do
    local side = lanes > 0 and -half + 2 * half * l / lanes or 0
    local d = castRayStatic(vec3(ax + nx * side, ay + ny * side, az + RAY_UP[1]), dir, len)
    if d and d < len - 0.05 then return true end
  end
  local d = castRayStatic(vec3(ax, ay, az + RAY_UP[2]), dir, len)
  return d ~= nil and d < len - 0.05
end

-- Centreline and road edges from the road graph (jumps to crossing roads rejected), plus the
-- walls on each side found by raycasts from where you drove. Offsets run along the left normal.
local function snapToRoad(g)
  local nodes = map.getMap().nodes
  local cx, cy, w, known = {}, {}, {}, {}
  for k = 1, g.n do
    local pos = vec3(g.x[k], g.y[k], g.z[k])
    local ok, a, b = pcall(map.findBestRoad, pos, vec3(g.hx[k], g.hy[k], 0))
    local na, nb = ok and a and nodes[a], ok and b and nodes[b]
    local good = false
    if na and nb then
      local ax, ay, bx, by = na.pos.x, na.pos.y, nb.pos.x, nb.pos.y
      local ex, ey = bx - ax, by - ay
      local l2 = ex * ex + ey * ey
      local f = l2 > 1e-6 and clamp(((g.x[k] - ax) * ex + (g.y[k] - ay) * ey) / l2, 0, 1) or 0
      local px, py = ax + ex * f, ay + ey * f
      local r = (na.radius or 3) + ((nb.radius or 3) - (na.radius or 3)) * f
      local off = sqrt((g.x[k] - px) ^ 2 + (g.y[k] - py) ^ 2)
      local jump = k > 1 and known[k - 1] and sqrt((px - cx[k - 1]) ^ 2 + (py - cy[k - 1]) ^ 2) > DS * 2.5
      if off < r + 6 and not jump then
        cx[k], cy[k], w[k], good = px, py, r, true
      end
    end
    if not good then cx[k], cy[k], w[k] = g.x[k], g.y[k], 0 end
    known[k] = good
  end
  -- light smoothing removes the corners between road-graph segments
  local sx, sy = {}, {}
  for k = 1, g.n do
    local ax, ay, c = 0, 0, 0
    for i = max(1, k - 2), min(g.n, k + 2) do
      if known[i] == known[k] then ax, ay, c = ax + cx[i], ay + cy[i], c + 1 end
    end
    sx[k], sy[k] = ax / c, ay / c
  end
  g.cx, g.cy, g.w, g.known = sx, sy, w, known
  -- left normals, your offset, and the road edges measured from the smoothed centreline
  -- (smoothing pulls it inside tight corners, so the edges come from the graph itself)
  g.nx, g.ny, g.alphaDrv, g.roadL, g.roadR = {}, {}, {}, {}, {}
  for k = 1, g.n do
    local a, b = max(1, k - 1), min(g.n, k + 1)
    local tx, ty = sx[b] - sx[a], sy[b] - sy[a]
    local tl = sqrt(tx * tx + ty * ty)
    if tl < 1e-6 then tx, ty, tl = g.hx[k], g.hy[k], 1 end
    tx, ty = tx / tl, ty / tl
    local nx, ny = -ty, tx
    g.nx[k], g.ny[k] = nx, ny
    g.alphaDrv[k] = (g.x[k] - sx[k]) * nx + (g.y[k] - sy[k]) * ny
    local shift = (cx[k] - sx[k]) * nx + (cy[k] - sy[k]) * ny
    g.roadL[k], g.roadR[k] = shift + w[k], shift - w[k]
  end
  -- at junctions the projection can snap to the crossing road for a point or two; a 5-point
  -- median removes those spikes (they would pinch the line into a kink) and keeps real changes
  local function median5(arr)
    local out = {}
    for k = 1, g.n do
      local c = {}
      for i = max(1, k - 2), min(g.n, k + 2) do
        if known[i] == known[k] then c[#c + 1] = arr[i] end
      end
      table.sort(c)
      out[k] = c[floor((#c + 1) / 2)]
    end
    return out
  end
  g.roadL, g.roadR = median5(g.roadL), median5(g.roadR)
  -- walls: the nearest static geometry on each side, the closest over neighbouring points
  -- (a single ray can slip between trees or barrier sections)
  local wl, wr = {}, {}
  local canRay = type(castRayStatic) == 'function'
  for k = 1, g.n do
    if canRay then
      local reach = max(RAY_MAX, (known[k] and w[k] or 0) + 6)
      local dl, dr = rayDist(g, k, 1, reach), rayDist(g, k, -1, reach)
      wl[k] = dl < reach and g.alphaDrv[k] + dl or nil
      wr[k] = dr < reach and g.alphaDrv[k] - dr or nil
    end
  end
  g.wallL, g.wallR = {}, {}
  for k = 1, g.n do
    local l, r
    for i = max(1, k - 1), min(g.n, k + 1) do
      if wl[i] then l = l and min(l, wl[i]) or wl[i] end
      if wr[i] then r = r and max(r, wr[i]) or wr[i] end
    end
    g.wallL[k], g.wallR[k] = l, r
  end
end

-- The lateral range the better line may use at each point: the road minus the car's half width
-- and a margin, widened to wherever you actually drove, and never closer to a wall than the car
-- allows. Unknown (off-graph) stretches stay close to your own line.
local function lineBounds(g, car, st)
  local half = car.halfWidth
  local lo, hi = {}, {}
  for k = 1, g.n do
    local ad = g.alphaDrv[k]
    local l, h
    if g.known[k] then
      l = max(g.roadR[k] - 1.5, min(g.roadR[k] + half + st.edge, ad))
      h = min(g.roadL[k] + 1.5, max(g.roadL[k] - half - st.edge, ad))
    else
      l, h = ad - 0.3, ad + 0.3
    end
    if g.wallL[k] then h = min(h, g.wallL[k] - half - st.wall) end
    if g.wallR[k] then l = max(l, g.wallR[k] + half + st.wall) end
    lo[k], hi[k] = min(l, ad), max(h, ad) -- you drove there, so your own line is always allowed
  end
  return lo, hi
end

local function smoothLine(g, lo, hi, alpha, px, py, passes)
  local n = g.n
  for _, pass in ipairs(passes) do
    local h, iters = pass[1], pass[2]
    for _ = 1, iters do
      for i = 1 + h, n - h do
        local lx = 0.5 * (px[i - h] + px[i + h]) - px[i]
        local ly = 0.5 * (py[i - h] + py[i + h]) - py[i]
        local a = clamp(alpha[i] + 0.8 * (lx * g.nx[i] + ly * g.ny[i]), lo[i], hi[i])
        alpha[i] = a
        px[i], py[i] = g.cx[i] + a * g.nx[i], g.cy[i] + a * g.ny[i]
      end
    end
  end
end

-- Minimum-curvature line: offsets from the centreline smoothed like an elastic band (coarse to
-- fine) inside lineBounds. Then every step of the line is raycast; where one would clip a wall,
-- or the way across from your line is blocked, the bounds close in toward your line and the
-- band is smoothed again.
local function betterLine(g, car, st)
  local n = g.n
  local lo, hi = lineBounds(g, car, st)
  local alpha, px, py = {}, {}, {}
  for k = 1, n do
    alpha[k] = clamp(g.alphaDrv[k], lo[k], hi[k])
    px[k], py[k] = g.cx[k] + alpha[k] * g.nx[k], g.cy[k] + alpha[k] * g.ny[k]
  end
  smoothLine(g, lo, hi, alpha, px, py, { { 6, 120 }, { 3, 120 }, { 1, 150 } })
  g.clipFixes = 0
  if type(castRayStatic) == 'function' then
    local gz = {}
    for k = 1, n do gz[k] = groundZ(g.x[k], g.y[k], g.z[k]) end
    for _ = 1, 4 do
      local bad, any, iz = {}, false, {}
      for k = 1, n do iz[k] = groundZ(px[k], py[k], g.z[k]) end
      for i = 1, n do
        local j = min(n, i + 1)
        if (j > i and segmentBlocked(px[i], py[i], iz[i], px[j], py[j], iz[j], car.halfWidth))
          or (abs(alpha[i] - g.alphaDrv[i]) > 0.3 and segmentBlocked(g.x[i], g.y[i], gz[i], px[i], py[i], iz[i], 0)) then
          bad[i], bad[j], any = true, true, true
        end
      end
      if not any then break end
      for k = 1, n do
        if bad[k] or bad[k - 1] or bad[k + 1] then
          local ad, f = g.alphaDrv[k], bad[k] and 0.5 or 0.25
          if alpha[k] < ad then lo[k] = lo[k] + (ad - lo[k]) * f end
          if alpha[k] > ad then hi[k] = hi[k] - (hi[k] - ad) * f end
          if bad[k] then g.clipFixes = g.clipFixes + 1 end
        end
      end
      smoothLine(g, lo, hi, alpha, px, py, { { 1, 150 } })
    end
  end
  g.lo, g.hi = lo, hi
  g.alpha, g.ix, g.iy = alpha, px, py
  -- signed Menger curvature over an 8 m chord, then a short moving average (positive = left)
  local kap = {}
  for i = 1, n do
    local a, b = max(1, i - 2), min(n, i + 2)
    local ax, ay = px[i] - px[a], py[i] - py[a]
    local bx, by = px[b] - px[i], py[b] - py[i]
    local cxv, cyv = px[b] - px[a], py[b] - py[a]
    local la, lb, lc = sqrt(ax * ax + ay * ay), sqrt(bx * bx + by * by), sqrt(cxv * cxv + cyv * cyv)
    kap[i] = (la > 0.1 and lb > 0.1 and lc > 0.1) and 2 * (ax * by - ay * bx) / (la * lb * lc) or 0
  end
  g.kappa = {}
  for i = 1, n do
    local s, c = 0, 0
    for j = max(1, i - 2), min(n, i + 2) do s, c = s + kap[j], c + 1 end
    g.kappa[i] = s / c
  end
end

-- analysis: the car model ------------------------------------------------------------

-- Moving average of a field over a time window (s), optionally of its absolute value.
local function movingAvg(seg, fld, win, useAbs)
  local out, n = {}, #seg
  local a, sum = 1, 0
  for i = 1, n do
    local x = seg[i][fld] or 0
    sum = sum + (useAbs and abs(x) or x)
    while seg[i][T] - seg[a][T] > win do
      local y = seg[a][fld] or 0
      sum = sum - (useAbs and abs(y) or y)
      a = a + 1
    end
    out[i] = sum / (i - a + 1)
  end
  return out
end

-- A level you reach consistently rather than once: from the per-event peaks, the 85th
-- percentile, and never the single best one when there are three or more.
local function robustTop(list)
  local c = {}
  for i = 1, #list do c[i] = list[i] end
  if #c == 0 then return nil end
  table.sort(c, function(a, b) return a > b end)
  if #c < 3 then return c[1] end
  return c[max(2, math.ceil(#c * 0.15))]
end

-- Runs where cond(i) holds for at least minDur seconds; calls fn(i0, i1) for each.
local function eachRun(seg, cond, keep, minDur, fn)
  local i, n = 1, #seg
  while i <= n do
    if cond(i) then
      local j = i
      while j < n and keep(j + 1) do j = j + 1 end
      if seg[j][T] - seg[i][T] >= minDur then fn(i, j) end
      i = j + 1
    else
      i = i + 1
    end
  end
end

-- What the car can do here, measured from the drive and the car's own numbers:
--  * aero: tyre load against speed on steady running (load = 1 + aero * v^2)
--  * grip per surface: the sustained (0.5 s) lateral peak of each corner, over the aero load,
--    taken robustly; surfaces with too few corners scale from the main one. Impacts (over
--    2.3 g, and the 1.5 s around them) don't count.
--  * braking: your sustained peaks, at least 0.9 of the cornering grip (tyres brake about as
--    well as they corner) and never more than the brakes' torque allows
--  * acceleration: your full-throttle pull per 5 m/s, with the engine's power curve filling
--    the speeds you never pulled through
-- The better line then aims at `margin` of these limits.
local function carModel(seg, car, margin)
  local n = #seg
  -- the tyres' own longitudinal acceleration (slope removed) and the vertical load, so hills,
  -- crests and compressions don't make the car look stronger or weaker than it is
  local latS, lonS, nfS = movingAvg(seg, LAT, 0.5, true), movingAvg(seg, TLON, 0.5), movingAvg(seg, NF, 0.5)
  local vmax = 0
  for i = 1, n do vmax = max(vmax, seg[i][SPD]) end
  -- impacts: no car corners or brakes at 2.3 g (plus aero, checked again below)
  local hit, lastHit = {}, -huge
  for i = 1, n do
    if sqrt(seg[i][LAT] ^ 2 + seg[i][LON] ^ 2) > 2.3 * G then lastHit = seg[i][T] end
    hit[i] = seg[i][T] - lastHit < 1.5
  end
  lastHit = huge
  for i = n, 1, -1 do
    if sqrt(seg[i][LAT] ^ 2 + seg[i][LON] ^ 2) > 2.3 * G then lastHit = seg[i][T] end
    hit[i] = hit[i] or lastHit - seg[i][T] < 1.5
  end

  -- aero from the tyre load channel (format 2 sessions)
  local l0, c0, num, den, cnt = 0, 0, 0, 0, 0
  for i = 1, n do
    local s = seg[i]
    if s[LOAD] and s[LOAD] > 0.3 and latS[i] < 0.25 * G and abs(lonS[i]) < 0.25 * G and s[SPD] > 5 and s[SPD] < 15 then
      l0, c0 = l0 + s[LOAD], c0 + 1
    end
  end
  l0 = c0 >= 60 and l0 / c0 or nil
  if l0 then
    for i = 1, n do
      local s = seg[i]
      local v = s[SPD]
      if s[LOAD] and s[LOAD] > 0.3 and latS[i] < 0.25 * G and abs(lonS[i]) < 0.25 * G and v > 15 then
        num, den, cnt = num + (s[LOAD] / l0 - 1) * v * v, den + v ^ 4, cnt + 1
      end
    end
  end
  local aero = (cnt >= 120 and den > 0) and clamp(num / den, 0, 0.5 / max(vmax * vmax, 400)) or 0
  local function loadAt(v) return 1 + aero * v * v end

  local function surfAt(i)
    local c = seg[i][SURF]
    return (c and c > 0) and c or nil
  end

  -- cornering grip events, per surface
  local byS, events = {}, 0
  eachRun(seg, function(i) return seg[i][SPD] > 8 and latS[i] > 0.3 * G and not hit[i] end,
    function(i) return latS[i] > 0.2 * G and not hit[i] end, 0.4, function(i0, i1)
      local pk, pi = 0, i0
      for i = i0, i1 do if latS[i] > pk then pk, pi = latS[i], i end end
      local cl = surfAt(pi) or 0
      byS[cl] = byS[cl] or {}
      table.insert(byS[cl], pk / (loadAt(seg[pi][SPD]) * clamp(nfS[pi], 0.5, 1.6)))
      events = events + 1
    end)
  local main, mainN = 0, -1
  for cl, list in pairs(byS) do if #list > mainN then main, mainN = cl, #list end end
  local coachLat, coachBrk = 0, 0
  if coDriverCoach and coDriverCoach.getGrip then coachLat, coachBrk = coDriverCoach.getGrip() end
  local mu, measured = {}, {}
  local mainMu = byS[main] and robustTop(byS[main]) or max((coachLat or 0) * G, 0.7 * G)
  mainMu = clamp(mainMu, 0.35 * G, 2.2 * G)
  local function relGrip(cl) return SURF_GRIP[cl] or 1 end
  for cl = 0, 5 do
    local list = byS[cl]
    if list and #list >= 3 then
      mu[cl], measured[cl] = clamp(robustTop(list), 0.2 * G, 2.2 * G), true
    else
      mu[cl] = mainMu * relGrip(cl) / relGrip(main)
    end
  end
  mu[main] = mainMu

  -- braking: your sustained peaks, as a share of the grip on that surface
  local ratios = {}
  eachRun(seg, function(i) return seg[i][SPD] > 8 and seg[i][BRK] > 0.3 and not hit[i] end,
    function(i) return seg[i][BRK] > 0.15 and not hit[i] end, 0.4, function(i0, i1)
      local pk, pi = 0, i0
      for i = i0, i1 do if -lonS[i] > pk then pk, pi = -lonS[i], i end end
      if pk > 0.2 * G then
        ratios[#ratios + 1] = pk / (loadAt(seg[pi][SPD]) * clamp(nfS[pi], 0.5, 1.6)) / mu[surfAt(pi) or main]
      end
    end)
  local brakeShare = max(robustTop(ratios) or 0, 0.9)
  if #ratios == 0 and (coachBrk or 0) > 0 then brakeShare = max(brakeShare, coachBrk * G / mainMu) end
  brakeShare = min(brakeShare, 1.5)
  local brakeCap = ((car.brakeN or 0) > 0 and (car.mass or 0) > 0) and 0.95 * car.brakeN / car.mass or nil

  -- acceleration per 5 m/s bin: your full-throttle pull, the engine's power curve elsewhere
  local bins = {}
  for i = 1, n do
    local s = seg[i]
    if s[THR] > 0.7 and s[TLON] > 0 and s[SPD] > 1 then
      local b = floor(s[SPD] / 5) + 1
      bins[b] = bins[b] or {}
      table.insert(bins[b], s[TLON])
    end
  end
  local power = ((car.powerKW or 0) > 0 and (car.mass or 0) > 0) and car.powerKW * 1000 / car.mass or nil
  local traction = mainMu * (car.driven == 'AWD' and 0.95 or 0.55)
  local function physAcc(v) return min(traction, 0.8 * power / max(v, 3)) end
  local data, ratiosA = {}, {}
  local topBin = floor(max(vmax, 10) / 5) + 2
  for b = 1, topBin do
    local list = bins[b]
    if list and #list >= 8 then
      data[b] = percentile(list, 0.9)
      if power then ratiosA[#ratiosA + 1] = data[b] / physAcc((b - 0.5) * 5) end
    end
  end
  local scale = #ratiosA > 0 and clamp(percentile(ratiosA, 0.5), 0.3, 1.3) or 0.8
  local acc, last = {}, 0.25 * G
  for b = 1, topBin do
    if data[b] then last = data[b]
    elseif power then last = scale * physAcc((b - 0.5) * 5) end
    acc[b] = max(last, 0.05 * G)
  end

  -- measured power at the wheels: mass x the tyres' acceleration x speed on full-throttle pulls, the
  -- 90th percentile per 5 m/s bin, best bin (drag and rolling resistance not added back, so a little
  -- under the real figure at speed; low bins are traction-limited and lose to higher ones)
  local pBins, measuredW, measuredV = {}, nil, nil
  if (car.mass or 0) > 0 then
    for i = 2, n do
      local s, p = seg[i], seg[i - 1]
      if s[THR] > 0.9 and s[SPD] > 8 and s[TLON] > 0 and not hit[i] and s[GEAR] == p[GEAR] and s[BRK] < 0.05 then
        local b = floor(s[SPD] / 5) + 1
        pBins[b] = pBins[b] or {}
        table.insert(pBins[b], car.mass * s[TLON] * s[SPD])
      end
    end
    for b, list in pairs(pBins) do
      if #list >= 15 then
        local p = percentile(list, 0.9)
        if not measuredW or p > measuredW then measuredW, measuredV = p, (b - 0.5) * 5 end
      end
    end
  end

  local function surfMu(cl) return mu[(cl and cl > 0) and cl or main] or mainMu end
  return {
    margin = margin, aero = aero, loadAt = loadAt, mu = mu, measured = measured, main = main,
    measuredW = measuredW, measuredV = measuredV,
    surfMu = surfMu, brakeShare = brakeShare, brakeCap = brakeCap, events = events,
    acc = acc, topBin = topBin, vcap = max(vmax * 1.03, 10), power = power,
    -- the model's limits at grid point k (surface class cl) and speed v, after the margin
    latAt = function(cl, v) return margin * surfMu(cl) * loadAt(v) end,
    brkAt = function(cl, v)
      local b = margin * brakeShare * surfMu(cl) * loadAt(v)
      return brakeCap and min(b, brakeCap) or b
    end,
    -- 0..1: brake pedal (share of brake torque) needed to brake at the limit here
    pedalAt = function(cl, v)
      local b = brakeShare * surfMu(cl) * loadAt(v)
      return brakeCap and min(1, b / (brakeCap / 0.95)) or 1
    end,
  }
end

local function accelAt(lim, v)
  if v >= lim.vcap then return 0 end
  local b = clamp(floor(v / 5) + 1, 1, lim.topBin)
  return lim.acc[b] or 0.25 * G
end

-- Surface class per grid point: the most common one within 3 points (the contact flickers).
local function gridSurfaces(g, lim)
  local out = {}
  for k = 1, g.n do
    local count, best, bestN = {}, lim.main, 0
    for i = max(1, k - 3), min(g.n, k + 3) do
      local c = g.surf[i]
      if c and c > 0 then
        count[c] = (count[c] or 0) + 1
        if count[c] > bestN then best, bestN = c, count[c] end
      end
    end
    out[k] = best
  end
  g.cls = out
end

-- Terrain along the better line: grade (sine of the slope, + = uphill), vertical curvature
-- (+ = compression, - = crest) and banking toward the inside of the corner (sine of the bank).
local function terrain(g)
  local n = g.n
  -- the grade comes from your own path (the road surface the car actually ran on): rays under a
  -- wide better line can land beside a road cut into a hillside. Rays are only used for banking,
  -- 1.5 m either side of your path, and a side that misses the ground counts as level.
  local z, tilt = {}, {}
  local rays = type(castRayStatic) == 'function'
  local function hit(x, y, zr)
    local d = castRayStatic(vec3(x, y, zr + 1.5), vec3(0, 0, -1), 4)
    return (d and d < 4) and zr + 1.5 - d or nil
  end
  for k = 1, n do
    z[k] = g.z[k]
    tilt[k] = 0
    if rays then
      local zl = hit(g.x[k] + 1.5 * g.nx[k], g.y[k] + 1.5 * g.ny[k], g.z[k])
      local zr = hit(g.x[k] - 1.5 * g.nx[k], g.y[k] - 1.5 * g.ny[k], g.z[k])
      if zl and zr then tilt[k] = clamp((zl - zr) / 3, -0.3, 0.3) end
    end
  end
  local function smooth(arr, w)
    local out = {}
    for k = 1, n do
      local s, c = 0, 0
      for j = max(1, k - w), min(n, k + w) do s, c = s + arr[j], c + 1 end
      out[k] = s / c
    end
    return out
  end
  z = smooth(z, 2)
  local grade, kv, bankIn = {}, {}, {}
  local h = 3 -- 12 m stencil: road surface detail is not a crest
  for k = 1, n do
    local a, b = max(1, k - 1), min(n, k + 1)
    local run = sqrt((g.x[b] - g.x[a]) ^ 2 + (g.y[b] - g.y[a]) ^ 2)
    grade[k] = run > 0.5 and clamp((z[b] - z[a]) / run, -0.35, 0.35) or 0
    local a2, b2 = max(1, k - h), min(n, k + h)
    local span = (b2 - a2) * DS / 2
    kv[k] = (k - a2 == h and b2 - k == h) and clamp((z[b2] - 2 * z[k] + z[a2]) / (span * span), -0.02, 0.02) or 0
    -- left side higher than right is banked toward a right-hand corner, and the other way round
    bankIn[k] = (g.kappa[k] >= 0) and -tilt[k] or tilt[k]
  end
  g.grade, g.kv, g.bankIn = smooth(grade, 2), smooth(kv, 2), smooth(bankIn, 2)
end

-- Three-pass quasi-steady-state speed profile along the better line, with slope, crests and banking.
local function idealSpeeds(g, lim)
  local n = g.n
  local ds, vlim, v = {}, {}, {}
  gridSurfaces(g, lim)
  terrain(g)
  -- vertical load at speed v: the slope's cosine plus the push of a compression (or lift of a crest)
  local function nfAt(i, vi)
    return clamp(sqrt(1 - g.grade[i] ^ 2) + vi * vi * g.kv[i] / G, 0.15, 2)
  end
  -- cornering acceleration available: tyre grip on the actual load, plus banking toward the inside
  local function latAt(i, vi) return max(0.5, lim.latAt(g.cls[i], vi) * nfAt(i, vi) + G * g.bankIn[i]) end
  for i = 1, n do
    local j = min(n, i + 1)
    ds[i] = max(0.5, sqrt((g.ix[j] - g.ix[i]) ^ 2 + (g.iy[j] - g.iy[i]) ^ 2 + (g.z[j] - g.z[i]) ^ 2))
    local k = abs(g.kappa[i])
    if k > 1e-5 then
      -- v^2 k = available lateral acceleration, which itself depends on v (aero, crests): solve by iteration
      local vi = lim.vcap
      for _ = 1, 6 do vi = 0.5 * vi + 0.5 * min(lim.vcap, sqrt(latAt(i, vi) / k)) end
      vlim[i] = vi
    else
      vlim[i] = lim.vcap
    end
  end
  local function avail(i, vi)
    local r = vi * vi * abs(g.kappa[i]) / latAt(i, vi)
    return sqrt(max(0.1, 1 - r * r))
  end
  v[1] = min(vlim[1], g.v[1])
  for i = 1, n - 1 do
    -- uphill takes away acceleration, downhill adds it; crests cut traction
    local a = accelAt(lim, v[i]) * min(1, nfAt(i, v[i])) * avail(i, v[i]) - G * g.grade[i]
    v[i + 1] = min(vlim[i + 1], sqrt(max(1, v[i] ^ 2 + 2 * a * ds[i])))
  end
  for i = n - 1, 1, -1 do
    -- uphill helps braking, downhill stretches the braking zone; crests cut the grip
    local b = lim.brkAt(g.cls[i + 1], v[i + 1]) * nfAt(i + 1, v[i + 1]) * avail(i + 1, v[i + 1]) + G * g.grade[i]
    v[i] = min(v[i], sqrt(v[i + 1] ^ 2 + 2 * max(0.3, b) * ds[i]))
  end
  local ax, ib, it, tI = {}, {}, {}, { 0 }
  for i = 1, n do
    local j = min(n, i + 1)
    ax[i] = j > i and (v[j] ^ 2 - v[i] ^ 2) / (2 * ds[i]) or 0
    -- what the tyres must do (gravity's part removed), as pedal: share of the limit times the pedal it needs
    local tyre = ax[i] + G * g.grade[i]
    local brkLim = lim.brkAt(g.cls[i], v[i]) * nfAt(i, v[i])
    ib[i] = clamp(-tyre / max(brkLim, 0.5), 0, 1) * lim.pedalAt(g.cls[i], v[i])
    local acc = accelAt(lim, v[i])
    it[i] = tyre > 0.02 * G and clamp(tyre / max(acc, 0.5), 0.15, 1) or (tyre > -0.05 * G and 0.15 or 0)
    if i > 1 then tI[i] = tI[i - 1] + 2 * ds[i - 1] / max(v[i - 1] + v[i], 0.5) end
  end
  g.iv, g.iax, g.ib, g.it, g.tI, g.vlim = v, ax, ib, it, tI, vlim
  g.delta = {}
  for i = 1, n do g.delta[i] = (g.t[i] - g.t[1]) - tI[i] end
end

-- analysis: corners --------------------------------------------------------------

-- First sample at or after t (n + 1 when none).
local function sampleAtT(seg, t)
  local lo, hi = 1, #seg + 1
  while lo < hi do
    local mid = floor((lo + hi) / 2)
    if seg[mid][T] < t then lo = mid + 1 else hi = mid end
  end
  return lo
end

local function rawRange(seg, t0, t1)
  local a = min(sampleAtT(seg, t0), #seg)
  local b = sampleAtT(seg, t1)
  if b > #seg or seg[b][T] > t1 then b = b - 1 end
  return a, max(1, max(a, b))
end

local unitMul, unitName = 3.6, 'km/h' -- set from the game's unit setting before each analysis
local function kmh(v) return floor(v * unitMul + 0.5) end

-- Finds corners as the ideal profile's braking zones, plus places you braked that it doesn't.
local function findCorners(g)
  local n, zones = g.n, {}
  local k = 1
  while k <= n do
    if g.iax[k] < -0.08 * G then
      local s0 = k
      while k <= n and g.iax[k] < -0.08 * G do k = k + 1 end
      local last = zones[#zones]
      if last and s0 - last.e0 < 4 then last.e0 = k - 1 else zones[#zones + 1] = { s0 = s0, e0 = k - 1 } end
    else
      k = k + 1
    end
  end
  local corners = {}
  for zi, z in ipairs(zones) do
    local nextStart = zones[zi + 1] and zones[zi + 1].s0 or n + 1
    local apex, best = z.s0, huge
    for i = z.s0, min(n, z.e0 + 30, nextStart - 1) do
      if g.iv[i] < best then apex, best = i, g.iv[i] end
    end
    if g.iv[z.s0] - g.iv[apex] >= 2.5 then
      local pickup = apex
      while pickup < min(n, nextStart - 1) and g.iax[pickup] <= 0.05 * G do pickup = pickup + 1 end
      local exit = clamp(pickup + 15, apex + 2, max(apex + 2, min(n, nextStart - 1)))
      exit = min(exit, n)
      corners[#corners + 1] = { s0 = z.s0, apex = apex, pickup = pickup, exit = exit }
    end
  end
  -- braking the model doesn't need: brake held for 8 m or more away from every ideal corner
  local i = 1
  while i <= n do
    if g.brk[i] > 0.25 then
      local r0 = i
      while i <= n and g.brk[i] > 0.1 do i = i + 1 end
      local r1 = i - 1
      if r1 - r0 >= 1 then
        local near = false
        for _, c in ipairs(corners) do
          if r1 >= c.s0 - 15 and r0 <= c.exit then near = true break end
        end
        if not near then
          local apex, best = r0, huge
          for j = r0, min(n, r1 + 15) do if g.v[j] < best then apex, best = j, g.v[j] end end
          corners[#corners + 1] = { s0 = r0, apex = apex, pickup = apex, exit = min(n, r1 + 20), unneeded = true }
        end
      end
    else
      i = i + 1
    end
  end
  table.sort(corners, function(a, b) return a.s0 < b.s0 end)
  return corners
end

-- Measures one corner against the ideal and writes the engineer's notes for it.
-- Balance per grid point (BeamLap's idea, our own method): g.bal[k] = 1 understeer (much less turn
-- than the steering asks for, near the grip limit), 2 oversteer (the rear out: the car points further
-- into the turn than it travels, or countersteer with some slide), 0 neutral. The steering gain
-- (path curvature per unit of steering input) is fitted on calm cornering of this drive. Flags need two
-- grid points in a row (8 m). g.steerGain is nil when there was too little calm cornering to fit it
-- (then only oversteer is flagged).
local function balanceOf(g, lim)
  local n, pi, atan2 = g.n, math.pi, math.atan2 or math.atan -- LuaJIT / Lua 5.3 (offline tests)
  local th, beta, kap = {}, {}, {}
  local function wrap(a) return (a + pi) % (2 * pi) - pi end
  for k = 1, n do
    local a, b = max(1, k - 1), min(n, k + 1)
    th[k] = atan2(g.y[b] - g.y[a], g.x[b] - g.x[a])
    beta[k] = math.deg(wrap(atan2(g.hy[k], g.hx[k]) - th[k]))
  end
  for k = 1, n do
    local a, b = max(1, k - 2), min(n, k + 2)
    kap[k] = b > a and wrap(th[b] - th[a]) / ((b - a) * DS) or 0
  end
  local mu = lim.mu[lim.main] or 0.9 * G
  local ratios = {}
  for k = 3, n - 2 do
    if g.v[k] > 8 and abs(g.lat[k]) < 0.3 * mu and abs(g.str[k]) > 0.03 and abs(beta[k]) < 2.5 and abs(kap[k]) > 0.004 then
      ratios[#ratios + 1] = kap[k] / g.str[k]
    end
  end
  local gain = #ratios >= 30 and percentile(ratios, 0.5) or nil
  if gain and abs(gain) < 0.01 then gain = nil end
  local raw = {}
  for k = 1, n do
    local v, s = g.v[k], kap[k] >= 0 and 1 or -1
    local rearOut = beta[k] * s
    local counter = gain and g.str[k] * gain * s < 0 and abs(g.str[k]) > 0.03
    raw[k] = 0
    if v > 5 and abs(kap[k]) > 0.003 and (rearOut > 5 or (counter and rearOut > 2.5)) then
      raw[k] = 2
    elseif gain and v > 8 and abs(g.str[k]) > 0.05 and abs(g.lat[k]) > 0.5 * mu and rearOut < 3 then
      local want = gain * g.str[k]
      if want * kap[k] >= 0 and abs(kap[k]) < 0.65 * abs(want) then raw[k] = 1 end
    end
  end
  local bal = {}
  for k = 1, n do
    local r = raw[k]
    bal[k] = (r > 0 and (raw[k - 1] == r or raw[k + 1] == r)) and r or 0
  end
  g.bal, g.steerGain = bal, gain
end

local function judgeCorner(g, seg, lim, st, car, c, prevExit)
  local n = g.n
  local f = {}
  local function add(key, weight, text) f[#f + 1] = { key = key, w = weight, text = text } end
  c.dir = g.kappa[c.apex] >= 0 and 'left' or 'right'
  c.radius = abs(g.kappa[c.apex]) > 1e-4 and floor(1 / abs(g.kappa[c.apex]) + 0.5) or nil
  c.loss = g.delta[c.exit] - g.delta[max(1, c.s0 - 5)]
  c.idealMin, c.idealExit = g.iv[c.apex], g.iv[c.exit]

  -- your main brake application for this corner (the run with the most brake)
  local lo = max(prevExit or 1, c.s0 - 40, 1)
  local runs, k = {}, lo
  while k <= c.apex do
    if g.brk[k] > 0.1 then
      local r = { a = k, sum = 0, peak = 0 }
      while k <= min(n, c.exit) and g.brk[k] > 0.05 do
        r.sum, r.peak = r.sum + g.brk[k], max(r.peak, g.brk[k])
        k = k + 1
      end
      r.b = k - 1
      runs[#runs + 1] = r
    else
      k = k + 1
    end
  end
  local run
  for _, r in ipairs(runs) do if not run or r.sum > run.sum then run = r end end

  local kd, vmin = c.s0, huge
  for i = max(1, c.s0 - 5), c.exit do if g.v[i] < vmin then kd, vmin = i, g.v[i] end end
  c.minSpeed, c.minIdx, c.exitSpeed = vmin, kd, g.v[c.exit]

  if c.unneeded then
    add('unneeded', 4, string.format('No brake needed here: it holds %d ' .. unitName .. ' flat', kmh(g.iv[c.apex])))
  end

  if run and not c.unneeded then
    c.brakeIdx = run.a
    c.brakeDiff = (c.s0 - run.a) * DS -- > 0: you braked earlier than needed
    -- how many metres count depends on the zone: long, low-grip stops scatter more
    local tol = max(st.brakeM, st.brakeShare * (c.apex - c.s0) * DS)
    c.tol = tol
    if c.brakeDiff > tol and vmin <= c.idealMin * 1.02 then
      add('early', c.brakeDiff / tol, string.format('Room to brake %d m later', floor(c.brakeDiff + 0.5)))
    elseif c.brakeDiff < -tol and vmin < c.idealMin * 0.95 then
      add('late', 2, string.format('Brake %d m earlier and you can carry more speed in', floor(-c.brakeDiff + 0.5)))
    end
    -- pedal shape from the raw samples
    local a, b = rawRange(seg, g.t[run.a] - 0.3, g.t[run.b] + 0.1)
    local peak, tPeak, t5 = 0, nil, nil
    for i = a, b do peak = max(peak, seg[i][BRK]) end
    for i = a, b do
      local x = seg[i][BRK]
      if not t5 and x >= 0.05 * peak then t5 = seg[i][T] end
      if not tPeak and x >= 0.9 * peak then tPeak = seg[i][T] end
    end
    c.brakePeak = peak
    c.brakeRise = (t5 and tPeak) and tPeak - t5 or nil
    local idealPeak = 0
    for i = c.s0, c.apex do idealPeak = max(idealPeak, g.ib[i]) end
    -- without ABS a softer squeeze is right, to find the locking point
    if peak > 0.15 and c.brakeRise and c.brakeRise > (car.abs == false and 0.45 or 0.3) then
      add('gentle', c.brakeRise * 3, string.format('Get to full brake sooner (it took %.1f s to build)', c.brakeRise))
    end
    -- the ideal trace is in pedal terms (strong brakes need less than 100% to reach the limit)
    if idealPeak > 0.45 and peak < 0.75 * idealPeak then
      add('lowpeak', 2, string.format('More brake available: %d%% used, about %d%% possible', floor(peak * 100), floor(idealPeak * 100)))
    end
    local runMax, dipped, dipLow = 0, false, nil
    for i = a, b do
      local x = seg[i][BRK]
      if x > runMax then runMax = x end
      if runMax > 0.2 and x < runMax - 0.15 then dipLow = min(dipLow or x, x) end
      if dipLow and x > dipLow + 0.1 then dipped = true end
    end
    if dipped then add('dip', 1.5, 'One smooth brake application instead of two') end
    -- trail braking: still on the brake when the steering starts to load
    local steerPeak = 0
    for i = run.a, c.exit do steerPeak = max(steerPeak, abs(g.str[i])) end
    if steerPeak > 0.08 then
      for i = run.a, c.exit do
        if abs(g.str[i]) > 0.2 * steerPeak then
          c.trail = g.brk[i] > 0.05
          break
        end
      end
      if c.trail == false and c.idealMin < g.iv[c.s0] * 0.85 then
        add('notrail', 1.5, 'Trail a little brake into the turn')
      end
    end
    -- coasting between brake release and throttle
    local ra = rawRange(seg, g.t[run.b], g.t[c.exit])
    local coast, released = 0, false
    for i = ra, #seg do
      local s, p = seg[i], seg[i - 1]
      if s[T] > g.t[c.exit] then break end
      if s[BRK] < 0.05 then released = true end
      if released then
        if s[THR] > 0.1 then break end
        if p and s[BRK] < 0.05 then coast = coast + (s[T] - p[T]) end
      end
    end
    c.coast = coast
    if coast > st.coast then add('coast', coast * 3, string.format('Close the %.1f s gap between brake and throttle', coast)) end
  elseif not c.unneeded and c.idealMin < g.iv[c.s0] * 0.9 then
    c.brakeDiff = nil
    if vmin > c.idealMin * 1.05 then add('nobrake', 1, 'Faster than the model here: nice') end
  end

  -- minimum speed and exit
  if not c.unneeded and vmin < c.idealMin * 0.95 then
    add('slow', (c.idealMin - vmin) / c.idealMin * 20,
      string.format('Carry more to the apex: %d, %d ' .. unitName .. ' possible', kmh(vmin), kmh(c.idealMin)))
  end
  if c.exitSpeed < c.idealExit * 0.93 then
    add('exit', (c.idealExit - c.exitSpeed) / c.idealExit * 15,
      string.format('Exit faster: %d, %d ' .. unitName .. ' possible', kmh(c.exitSpeed), kmh(c.idealExit)))
  end

  -- throttle pickup after the apex
  local dp
  for i = max(kd, c.apex - 3), min(n, c.exit + 10) do
    if g.thr[i] > 0.2 then dp = i break end
  end
  if dp and not c.unneeded then
    c.throttleIdx = dp
    c.throttleLateM = (dp - c.pickup) * DS
    c.throttleLateS = g.t[dp] - g.t[c.pickup]
    if c.throttleLateS > 0.5 or c.throttleLateM > 15 then
      add('latethrottle', c.throttleLateS * 3, string.format('Throttle can come %.1f s (%d m) sooner', c.throttleLateS, floor(c.throttleLateM + 0.5)))
    end
  end

  -- steering corrections
  local a, b = rawRange(seg, g.t[run and run.a or c.s0], g.t[c.exit])
  local dir, ext, flips = 0, seg[a][STR], 0
  for i = a + 1, b do
    local x = seg[i][STR]
    if dir >= 0 and x < ext - 0.03 then
      if dir > 0 then flips = flips + 1 end
      dir, ext = -1, x
    elseif dir <= 0 and x > ext + 0.03 then
      if dir < 0 then flips = flips + 1 end
      dir, ext = 1, x
    elseif (dir > 0 and x > ext) or (dir < 0 and x < ext) then
      ext = x
    end
  end
  local dur = max(seg[b][T] - seg[a][T], 0.5)
  c.sawRate = flips / dur
  if c.sawRate > 2 and flips >= 3 then add('saw', 1.5, string.format('Smoother hands: %d corrections in %.1f s', flips, dur)) end

  -- line: how far from the ideal apex (positive = wide of it)
  if g.known[c.apex] and not c.unneeded then
    local inside = g.kappa[c.apex] >= 0 and 1 or -1
    c.apexGap = (g.alpha[c.apex] - g.alphaDrv[c.apex]) * inside
    if c.apexGap > st.wide then add('wide', c.apexGap, string.format('Apex %.1f m tighter', c.apexGap)) end
  end

  -- grip use
  local over, tot = 0, 0
  for i = c.s0, c.exit do
    tot = tot + 1
    local full = lim.latAt(g.cls[i], g.v[i]) / lim.margin -- the limit itself, not the target
    if sqrt(g.lon[i] ^ 2 + g.lat[i] ^ 2) > 0.85 * full then over = over + 1 end
  end
  c.gripUse = tot > 0 and over / tot or 0

  table.sort(f, function(p, q) return p.w > q.w end)
  c.findings = f
  local parts = {}
  for i = 1, min(2, #f) do parts[i] = f[i].text end
  c.note = #parts > 0 and table.concat(parts, '. ') .. '.' or (c.loss < 0.1 and 'On the pace here.' or 'Small losses spread through the corner.')

  -- what went well, in order of how much it matters (the review leads with these)
  local good = {}
  local function praise(key, ok, text) if ok then good[#good + 1] = { key = key, text = text } end end
  if not c.unneeded then
    praise('pace', c.loss < 0.1, 'On the better line\'s pace')
    praise('brakepoint', run and c.brakeDiff and c.tol and abs(c.brakeDiff) <= 0.6 * c.tol and vmin >= c.idealMin * 0.95, 'Brake point on the mark')
    praise('carry', vmin >= c.idealMin * 0.97, vmin >= c.idealMin and string.format('Full speed to the apex (%d ' .. unitName .. ')', kmh(vmin))
      or string.format('Carried the speed: %d of %d ' .. unitName .. ' at the apex', kmh(vmin), kmh(c.idealMin)))
    praise('exitgood', c.exitSpeed >= c.idealExit * 0.97, 'Strong exit')
    praise('trail', c.trail == true and c.idealMin < g.iv[c.s0] * 0.85, 'Trail-braked into the turn')
    praise('firm', c.brakeRise and c.brakeRise <= 0.2 and (c.brakePeak or 0) > 0.5, 'Firm, quick brake application')
    praise('throttle', c.throttleLateS and c.throttleLateS <= 0.25, 'Early on the throttle')
    praise('nocoast', run and (c.coast or 1) < 0.1, 'Straight from brake to throttle')
    praise('apex', c.apexGap and c.apexGap <= 0.5, 'Hit the apex')
    praise('smooth', flips <= 1, 'Smooth, single steering input')
  end
  c.good = good

  -- incidents: a crash, a spin, an off or the car lost, which is not driving to coach. The
  -- corner says what happened, and stays out of the tips, the positives and the clean gap.
  local i0, i1 = rawRange(seg, g.t[max(1, c.s0 - 5)], g.t[c.exit])
  local slipT, maxSlip, hit = 0, 0, false
  for i = i0, i1 do
    local sm, pv = seg[i], seg[i - 1]
    local vh, hl = sqrt(sm[VX] ^ 2 + sm[VY] ^ 2), sqrt(sm[DX] ^ 2 + sm[DY] ^ 2)
    if vh > 3 and hl > 0.1 then
      local ang = math.deg(math.acos(clamp((sm[VX] * sm[DX] + sm[VY] * sm[DY]) / (vh * hl), -1, 1)))
      maxSlip = max(maxSlip, ang)
      if ang > 50 and pv then slipT = slipT + (sm[T] - pv[T]) end
    end
    if sqrt(sm[LAT] ^ 2 + sm[LON] ^ 2) > 2.5 * G then hit = true end
  end
  local off = 0
  for i = c.s0, c.exit do
    if g.known[i] and (g.alphaDrv[i] > g.roadL[i] + 2 or g.alphaDrv[i] < g.roadR[i] - 2) then off = off + 1 end
  end
  local slow = vmin < c.idealMin * 0.7
  local kind
  if hit then kind = 'crash' -- no driving input gives 2.5 g
  elseif (slipT > 0.5 or maxSlip > 100) and slow then kind = 'spin'
  elseif off >= 3 and slow then kind = 'off'
  elseif vmin < c.idealMin * 0.4 and c.idealMin > 8 then kind = 'lost' end
  if kind and not c.unneeded then
    c.incident = kind
    c.findings, c.good = {}, {}
    c.note = ({
      crash = 'Crashed here',
      spin = 'Spun here',
      off = 'Went off the road here',
      lost = string.format('Lost it here (down to %d ' .. unitName .. ')', kmh(vmin)),
    })[kind] .. ': not counted in the tips or the clean gap.'
  end
end

local TIPS = {
  early = 'Try a later brake marker: the car stops better than you think.',
  late = 'Brake a touch earlier and release smoothly to the apex: you will carry more speed in.',
  gentle = 'Get to full brake quickly, then ease off: the first half second does the most work.',
  lowpeak = 'There is more brake available: lean on the pedal harder at the start.',
  dip = 'Aim for one smooth brake application per corner.',
  notrail = 'Keep a little brake on as you turn in, then let it off toward the apex.',
  coast = 'Roll straight from brake to throttle, with no gap.',
  latethrottle = 'Pick up the throttle a bit sooner after the apex, gently at first.',
  saw = 'One smooth steering input, then hold it.',
  wide = 'Use the whole road: outside, apex, outside.',
  slow = 'Let the car roll more speed to the apex: the corners allow more than you take.',
  exit = 'Focus on exits: they set your speed for the whole next straight.',
  unneeded = 'Some corners need only a lift, or nothing at all.',
}

-- strengths across the drive, phrased with how often they showed up
local STRENGTHS = {
  pace = 'On the better line\'s pace in %d corners',
  brakepoint = 'Brake points on the mark in %d corners',
  carry = 'Carried full apex speed in %d corners',
  exitgood = 'Strong exits in %d corners',
  trail = 'Trail-braked into %d corners',
  firm = 'Firm, quick braking in %d corners',
  throttle = 'Early on the throttle in %d corners',
  nocoast = 'No coasting between the pedals in %d corners',
  apex = 'Hit the apex in %d corners',
  smooth = 'Smooth steering in %d corners',
}
local STRENGTH_ORDER = { 'pace', 'brakepoint', 'carry', 'exitgood', 'trail', 'firm', 'throttle', 'nocoast', 'apex', 'smooth' }

-- analysis: laps -----------------------------------------------------------------

-- With laps from coDriverLaps, every lap is laid onto the best one: each of its 4 m points is
-- projected onto the best lap's points (the station only moving forward), so all laps share
-- stations and turn numbers. That gives the time to the best lap at every point, sector times,
-- each turn's best pass and a theoretical best lap from the best 50 m stretches.
local LAP_SECTORS, LAP_CELL, LAP_TURN_M = 3, 50, 30
-- "Where the time is": each 50 m cell split in 5 (about 10 m). The quicker lap owns a cell; a run
-- under 3 cells between two runs of one other owner is merged into them; stretches under 0.02 s
-- or 0.01 s per 100 m are dropped; the rest are ranked by rate. Top 8 losses, top 3 gains per lap.
local STRETCH = { sub = 5, flicker = 3, minGain = 0.02, minRate = 0.01, top = 8, ahead = 3 }

-- Runs of cells with one owner (own[c]; nil = no data, which ends a run), short runs merged as
-- above, each with its gain: the sum of gainOf(c, owner) over its cells.
local function ownerRuns(own, n, gainOf)
  local runs = {}
  for c = 1, n do
    local o, r = own[c], runs[#runs]
    if o ~= nil and r and r.o == o and r.c1 == c - 1 then r.c1 = c
    elseif o ~= nil then runs[#runs + 1] = { o = o, c0 = c, c1 = c } end
  end
  local i = 2
  while i < #runs do
    local p, r, q = runs[i - 1], runs[i], runs[i + 1]
    if r.c1 - r.c0 + 1 < STRETCH.flicker and p.o == q.o and p.c1 == r.c0 - 1 and r.c1 == q.c0 - 1 then
      p.c1 = q.c1
      table.remove(runs, i + 1)
      table.remove(runs, i)
    else
      i = i + 1
    end
  end
  for _, r in ipairs(runs) do
    local g = 0
    for c = r.c0, r.c1 do g = g + gainOf(c, r.o) end
    r.gain = g
  end
  return runs
end

local function lapAnalysis(out, sess)
  local laps = type(sess.laps) == 'table' and sess.laps or {}
  local P = out.points
  local n = #P.s
  if #laps == 0 or n < 20 then return nil end
  local function firstAtOrAfter(t)
    local lo, hi = 1, n + 1
    while lo < hi do
      local m = floor((lo + hi) / 2)
      if P.t[m] < t then lo = m + 1 else hi = m end
    end
    return lo
  end
  local L = {}
  for _, lap in ipairs(laps) do
    local t0, t1 = tonumber(lap.t0), tonumber(lap.t1)
    -- (laps found by older versions could include a long stop: under 5 m/s on average is no lap)
    local stopped = tonumber(lap.len) and t0 and t1 and (t1 - t0) > tonumber(lap.len) / 5
    if type(lap) == 'table' and t0 and t1 and t1 > t0 and not stopped then
      local i0, i1 = firstAtOrAfter(t0), firstAtOrAfter(t1) - 1
      if i1 - i0 >= 10 then
        L[#L + 1] = { n = tonumber(lap.n) or #L + 1, time = tonumber(lap.time) or (t1 - t0), valid = lap.valid == true,
          reason = lap.reason, partial = lap.partial or nil, t0 = t0, t1 = t1, i0 = i0, i1 = i1,
          route = lap.route, hasReplay = findPart(sess, t0 + 1) ~= nil }
      end
    end
  end
  if #L == 0 then return nil end
  -- the reference: the best valid lap (else the fastest complete one)
  local ref
  for _, l in ipairs(L) do
    if l.valid and (not ref or l.time < ref.time) then ref = l end
  end
  if not ref then
    for _, l in ipairs(L) do
      if not l.partial and (not ref or l.time < ref.time) then ref = l end
    end
  end
  P.ld, P.lap, P.st = {}, {}, {} -- time to the best lap, lap key, station along the best lap
  for i = 1, n do P.ld[i], P.lap[i], P.st[i] = 0, 0, 0 end
  for li, l in ipairs(L) do
    l.key = li
    for i = l.i0, l.i1 do P.lap[i] = li end
  end
  local res = { list = L, ref = ref and ref.key or nil }
  if not ref then return res end

  -- the reference line: stations along the best lap
  local m = ref.i1 - ref.i0 + 1
  local rx, ry, rs, rt = {}, {}, {}, {}
  for k = 1, m do
    local i = ref.i0 + k - 1
    rx[k], ry[k], rt[k] = P.x[i], P.y[i], P.t[i] - ref.t0
    rs[k] = k == 1 and 0 or rs[k - 1] + sqrt((rx[k] - rx[k - 1]) ^ 2 + (ry[k] - ry[k - 1]) ^ 2)
  end
  local refLen = rs[m]
  local function refTime(s) -- reference lap time at station s
    if s <= 0 then return 0 end
    if s >= refLen then return rt[m] end
    local lo, hi = 1, m
    while hi - lo > 1 do
      local mid = floor((lo + hi) / 2)
      if rs[mid] < s then lo = mid else hi = mid end
    end
    local f = (s - rs[lo]) / max(1e-6, rs[hi] - rs[lo])
    return rt[lo] + (rt[hi] - rt[lo]) * f
  end

  -- each lap of the same route projected onto the reference: station (only increasing) and
  -- lap time per point
  for _, l in ipairs(L) do if l.route == ref.route then
    local st, tl = {}, {}
    local j, best = 1, huge
    for k = 1, min(m - 1, 40) do -- start: the reference point nearest the lap's first point
      local d = (P.x[l.i0] - rx[k]) ^ 2 + (P.y[l.i0] - ry[k]) ^ 2
      if d < best then best, j = d, k end
    end
    local sMax = 0
    for i = l.i0, l.i1 do
      local px, py = P.x[i], P.y[i]
      local bd, bs, bj = huge, nil, j
      for k = max(1, j - 3), min(m - 1, j + 30) do
        local ex, ey = rx[k + 1] - rx[k], ry[k + 1] - ry[k]
        local l2 = ex * ex + ey * ey
        local f = l2 > 0 and clamp(((px - rx[k]) * ex + (py - ry[k]) * ey) / l2, 0, 1) or 0
        local d = (px - rx[k] - ex * f) ^ 2 + (py - ry[k] - ey * f) ^ 2
        if d < bd then bd, bs, bj = d, rs[k] + (rs[k + 1] - rs[k]) * f, k end
      end
      if bs and bd < 25 * 25 then
        j = bj
        sMax = max(sMax, bs)
      end
      st[#st + 1], tl[#tl + 1] = sMax, P.t[i] - l.t0
      P.st[i] = round(sMax, 1)
      P.ld[i] = l == ref and 0 or round((P.t[i] - l.t0) - refTime(sMax), 2)
    end
    l.st, l.tl, l.reach = st, tl, sMax
  end end

  -- the route's best ever (a best lap kept per route, usually from another drive), laid onto this
  -- drive's best lap like the laps above, for "compare with your best ever"
  local ev, evd = nil, M.loadBestEver and sess.level and ref.route and M.loadBestEver(sess.level, ref.route)
  if evd then
    local px, py, pt, pv = evd.pts.x, evd.pts.y, evd.pts.t, evd.pts.v
    local st, tl = {}, {}
    local j, best = 1, huge
    for k = 1, min(m - 1, 40) do
      local d = (px[1] - rx[k]) ^ 2 + (py[1] - ry[k]) ^ 2
      if d < best then best, j = d, k end
    end
    local sMax, off = 0, 0
    for i = 1, #px do
      local bd, bs, bj = huge, nil, j
      for k = max(1, j - 3), min(m - 1, j + 30) do
        local ex, ey = rx[k + 1] - rx[k], ry[k + 1] - ry[k]
        local l2 = ex * ex + ey * ey
        local f = l2 > 0 and clamp(((px[i] - rx[k]) * ex + (py[i] - ry[k]) * ey) / l2, 0, 1) or 0
        local d = (px[i] - rx[k] - ex * f) ^ 2 + (py[i] - ry[k] - ey * f) ^ 2
        if d < bd then bd, bs, bj = d, rs[k] + (rs[k + 1] - rs[k]) * f, k end
      end
      if bs and bd < 25 * 25 then j, sMax = bj, max(sMax, bs) else off = off + 1 end
      st[i], tl[i] = sMax, pt[i]
    end
    -- the same road: it covered the lap and stayed on it
    if sMax > refLen * 0.9 and off < #px * 0.1 and tonumber(evd.time) then
      ev = { st = st, tl = tl, reach = sMax, time = tonumber(evd.time), partial = false, v = pv }
    end
  end

  -- a lap's own time at a reference station (nil past where it got to)
  local function lapTime(l, s)
    if not l.st then return nil end
    if s <= 0 then return 0 end
    if not l.partial and s >= refLen - 1 then return l.time end
    if s > l.reach then return nil end
    local st, tl = l.st, l.tl
    local lo, hi = 1, #st
    if st[hi] < s then return nil end
    while hi - lo > 1 do
      local mid = floor((lo + hi) / 2)
      if st[mid] < s then lo = mid else hi = mid end
    end
    local f = (s - st[lo]) / max(1e-6, st[hi] - st[lo])
    return tl[lo] + (tl[hi] - tl[lo]) * clamp(f, 0, 1)
  end
  local function between(l, a, b)
    local ta, tb = lapTime(l, a), lapTime(l, b)
    return ta and tb and tb - ta or nil
  end

  -- sectors, and the theoretical best from the best 50 m stretches of the valid laps
  local bounds = {}
  for k = 0, LAP_SECTORS do bounds[k + 1] = refLen * k / LAP_SECTORS end
  local bestSec = {}
  for _, l in ipairs(L) do
    l.sectors = {}
    for k = 1, LAP_SECTORS do
      local v = between(l, bounds[k], bounds[k + 1])
      l.sectors[k] = v and round(v, 2) or -1
      if v and l.valid and (not bestSec[k] or v < bestSec[k]) then bestSec[k] = v end
    end
    l.delta = l.st and round(l.time - ref.time, 2) or nil
  end
  local cells = max(1, floor(refLen / LAP_CELL + 0.5))
  local theo, theoOk = 0, true
  for c = 1, cells do
    local a, b = refLen * (c - 1) / cells, refLen * c / cells
    local bc
    for _, l in ipairs(L) do
      if l.valid then
        local v = between(l, a, b)
        if v and (not bc or v < bc) then bc = v end
      end
    end
    if bc then theo = theo + bc else theoOk = false end
  end
  res.sectors = {}
  for k = 1, LAP_SECTORS do res.sectors[k] = bestSec[k] and round(bestSec[k], 2) or -1 end
  res.theoretical = theoOk and round(theo, 2) or nil
  -- the same over the 10 m cells (5 to each 50 m cell, so never slower than the 50 m one). Each
  -- lap's time at every cell boundary goes out too (l.tAt, 3 decimals, -1 = not reached): the
  -- stretches below and the panel's compare of any two laps both work from it.
  local nc = cells * STRETCH.sub
  local cellM = refLen / nc
  local raw = {}
  for li, l in ipairs(L) do if l.st then
    local r, at = {}, {}
    for k = 0, nc do
      local v = lapTime(l, cellM * k)
      r[k + 1], at[k + 1] = v, v and round(v, 3) or -1
    end
    raw[li], l.tAt = r, at
  end end
  if ev then -- the best ever's time and speed at every cell boundary
    local at, vat = {}, {}
    for k = 0, nc do
      local s = cellM * k
      local v = lapTime(ev, s)
      at[k + 1] = v and round(v, 3) or -1
      local lo, hi = 1, #ev.st
      while hi - lo > 1 do
        local mid = floor((lo + hi) / 2)
        if ev.st[mid] < s then lo = mid else hi = mid end
      end
      local f = ev.st[hi] > ev.st[lo] and clamp((s - ev.st[lo]) / (ev.st[hi] - ev.st[lo]), 0, 1) or 0
      vat[k + 1] = round((ev.v[lo] or 0) + ((ev.v[hi] or 0) - (ev.v[lo] or 0)) * f, 2)
    end
    ev.tAt, ev.vAt = at, vat
  end
  local theo10, theo10Ok = 0, theoOk
  for c = 1, nc do
    local bc
    for li, l in ipairs(L) do
      local r = raw[li]
      if l.valid and r and r[c] and r[c + 1] and (not bc or r[c + 1] - r[c] < bc) then bc = r[c + 1] - r[c] end
    end
    if bc then theo10 = theo10 + bc else theo10Ok = false end
  end
  res.theoretical10 = theo10Ok and round(theo10, 2) or nil
  res.cells, res.cellM = nc, round(cellM, 4)
  local nv, sum, sum2 = 0, 0, 0
  for _, l in ipairs(L) do
    if l.valid then nv, sum, sum2 = nv + 1, sum + l.time, sum2 + l.time * l.time end
  end
  res.valid = nv
  res.spread = nv >= 2 and round(sqrt(max(0, sum2 / nv - (sum / nv) ^ 2)), 2) or nil
  res.length = round(refLen)

  -- turns: the best lap's corners, found again in every lap by station
  local turns = {}
  local function refStation(i) return rs[clamp(i - ref.i0 + 1, 1, m)] end
  for _, c in ipairs(out.corners) do
    if c.tStart >= ref.t0 - 1 and c.tStart < ref.t1 then
      turns[#turns + 1] = { id = #turns + 1, dir = c.dir, s = refStation(c.iApex),
        a = refStation(c.i0), b = refStation(c.i1), unneeded = c.unneeded }
      c.lap, c.turn = ref.key, #turns
    end
  end
  local function lapOf(c)
    for _, l in ipairs(L) do
      if c.iApex >= l.i0 and c.iApex <= l.i1 then return l end
    end
  end
  for _, c in ipairs(out.corners) do
    local l = not c.turn and lapOf(c)
    if l then c.lap = l.key end
    if l and l.st then
      local sA = l.st[c.iApex - l.i0 + 1]
      local bt, bd = nil, LAP_TURN_M
      for _, tn in ipairs(turns) do
        local d = abs(tn.s - sA)
        if tn.dir == c.dir and d < bd then bt, bd = tn, d end
      end
      if bt then c.turn = bt.id end
    end
  end
  -- each turn's time in every lap (the reference's window), its best pass, and who lost where
  for _, tn in ipairs(turns) do
    tn.times = {}
    for li, l in ipairs(L) do
      local v = between(l, tn.a, tn.b)
      tn.times[li] = v and round(v, 2) or -1
      if v and l.valid and (not tn.best or v < tn.best) then tn.best, tn.bestLap = v, li end
    end
    if tn.best then tn.best = round(tn.best, 2) end
  end

  -- where the time is: every lap against the best lap, cell by cell (from the rounded boundary
  -- times, as the panel has them); the best lap against the quickest valid lap of each cell
  local function cellT(l, c)
    local at = l.tAt
    local a, b = at and at[c], at and at[c + 1]
    return a and b and a >= 0 and b >= 0 and b - a or nil
  end
  local function placeAt(s) -- "T6 exit", "40 m before T7"
    local prev, nxt
    for _, tn in ipairs(turns) do
      if s >= tn.a and s <= tn.b then return 'T' .. tn.id .. (s < tn.s and ' entry' or ' exit') end
      if tn.b < s and (not prev or tn.b > prev.b) then prev = tn end
      if tn.a > s and (not nxt or tn.a < nxt.a) then nxt = tn end
    end
    local dp, dn = prev and s - prev.b, nxt and nxt.a - s
    if dp and (not dn or dp <= dn) then
      return dp < 15 and ('T' .. prev.id .. ' exit') or string.format('%d m after T%d', floor(dp / 10 + 0.5) * 10, prev.id)
    end
    if dn then return dn < 15 and ('T' .. nxt.id .. ' entry') or string.format('%d m before T%d', floor(dn / 10 + 0.5) * 10, nxt.id) end
    return string.format('%.2f km', s / 1000)
  end
  local function stretchesOf(runs, mine, limit)
    local out, total = {}, 0
    for _, r in ipairs(runs) do
      local s0, s1 = (r.c0 - 1) * cellM, r.c1 * cellM
      local rate = r.gain / (s1 - s0) * 100
      if mine(r.o) and r.gain >= STRETCH.minGain and rate >= STRETCH.minRate then
        total = total + r.gain
        local near, nd = nil, huge
        for _, tn in ipairs(turns) do
          local d = max(0, tn.a - s1, s0 - tn.b)
          if d < nd then near, nd = tn.id, d end
        end
        local a, b = placeAt(s0), placeAt(s1)
        local ta = a:match('^(T%d+) e')
        out[#out + 1] = { s0 = round(s0), s1 = round(s1), turn = near, gain = round(r.gain, 2), rate = round(rate, 3), by = r.o,
          where = a == b and a or (ta and ta == b:match('^(T%d+) e') and ta) or (a .. ' to ' .. b) }
      end
    end
    table.sort(out, function(x, y) if x.rate ~= y.rate then return x.rate > y.rate end return x.s0 < y.s0 end)
    for k = #out, limit + 1, -1 do out[k] = nil end
    return out, round(total, 2)
  end
  for _, l in ipairs(L) do if l.tAt then
    local own = {}
    if l == ref then
      for c = 1, nc do
        local bo, bv = cellT(ref, c) and ref.key, cellT(ref, c)
        for _, x in ipairs(L) do
          local v = x.valid and cellT(x, c)
          if v and (not bv or v < bv) then bo, bv = x.key, v end
        end
        own[c] = bo
      end
      local runs = ownerRuns(own, nc, function(c, o)
        local a, b = cellT(ref, c), cellT(L[o], c)
        return a and b and a - b or 0
      end)
      l.stretches, l.lost = stretchesOf(runs, function(o) return o ~= ref.key end, STRETCH.top)
    else
      for c = 1, nc do
        local a, b = cellT(l, c), cellT(ref, c)
        if a and b then own[c] = (a - b > 0 or (a == b and ref.key < l.key)) and ref.key or l.key end -- a tie: the lower key
      end
      local runs = ownerRuns(own, nc, function(c, o)
        local d = cellT(l, c) - cellT(ref, c)
        return o == ref.key and d or -d
      end)
      l.stretches, l.lost = stretchesOf(runs, function(o) return o == ref.key end, STRETCH.top)
      l.ahead, l.gained = stretchesOf(runs, function(o) return o == l.key end, STRETCH.ahead)
    end
  end end
  for li, l in ipairs(L) do
    local losses = {}
    for _, tn in ipairs(turns) do
      local v = tn.times[li]
      if v >= 0 and tn.best then losses[#losses + 1] = { turn = tn.id, loss = round(v - tn.best, 2) } end
    end
    table.sort(losses, function(a, b) return a.loss > b.loss end)
    l.top = {}
    for k = 1, min(3, #losses) do if losses[k].loss >= 0.05 then l.top[#l.top + 1] = losses[k] end end
    l.st, l.tl, l.reach = nil, nil, nil
  end
  for _, c in ipairs(out.corners) do
    local tn = c.turn and turns[c.turn]
    if tn and tn.best then
      for li, l in ipairs(L) do
        if li == c.lap and tn.times[li] >= 0 then c.vsBest = round(tn.times[li] - tn.best, 2) end
      end
      c.bestLap = tn.bestLap
    end
  end
  -- this drive's best lap against the best ever: where it lost and won time (owner 0 = best ever)
  if ev and ref.tAt then
    local own = {}
    for c = 1, nc do
      local a, b = cellT(ref, c), cellT(ev, c)
      if a and b then own[c] = (a - b > 0) and 0 or ref.key end
    end
    local runs = ownerRuns(own, nc, function(c, o)
      local d = cellT(ref, c) - cellT(ev, c)
      return o == 0 and d or -d
    end)
    local lost, lostT = stretchesOf(runs, function(o) return o == 0 end, STRETCH.top)
    local won, wonT = stretchesOf(runs, function(o) return o == ref.key end, STRETCH.ahead)
    local lx, ly = {}, {}
    for i = 1, #evd.pts.x, 2 do lx[#lx + 1], ly[#ly + 1] = evd.pts.x[i], evd.pts.y[i] end
    res.bestEver = { time = round(ev.time, 3), date = evd.date, car = evd.car, session = evd.session,
      same = abs(ev.time - ref.time) < 0.002, tAt = ev.tAt, vAt = ev.vAt, line = { x = lx, y = ly },
      stretches = lost, ahead = won, lost = lostT, gained = wonT }
  end
  res.turns = turns
  return res
end

local function analyzeSession(sess)
  if settings.getValue('uiUnitLength') == 'imperial' then unitMul, unitName = 2.23694, 'mph' else unitMul, unitName = 3.6, 'km/h' end
  local segs = splitSegments(sess.samples)
  local out = { segments = 0, corners = {}, points = {}, tDrive = 0, tIdeal = 0 }
  -- the model's 4 m grid (map, ideal traces, corner indices) ...
  local pts = { s = {}, x = {}, y = {}, ix = {}, iy = {}, lx = {}, ly = {}, rx = {}, ry = {}, v = {}, iv = {},
    ib = {}, it = {}, d = {}, t = {}, seg = {}, bal = {} }
  -- ... and your inputs at full rate for the charts
  local tr = { s = {}, v = {}, thr = {}, brk = {}, bp = {}, str = {}, gear = {}, rpm = {}, lat = {}, seg = {} }
  local car = {}
  for k, v in pairs(type(sess.car) == 'table' and sess.car or {}) do car[k] = v end
  car.halfWidth = clamp(tonumber(car.halfWidth) or 0.95, 0.6, 1.4)
  local sOff, dOff, cid = 0, 0, 0
  local model, modelLen, clipFixes, rayed = nil, 0, 0, type(castRayStatic) == 'function'
  for si, seg in ipairs(segs) do
    if #seg >= 40 then
      addAccelerations(seg)
      local g = toGrid(seg)
      if g.n * DS >= 300 then
        out.segments = out.segments + 1
        snapToRoad(g)
        -- style: the setting, or a guess from the level, the surface and the walls
        local loose = 0
        for k = 1, g.n do if (g.surf[k] or 0) >= 3 then loose = loose + 1 end end
        local style = options.style
        if style ~= 'rally' and style ~= 'circuit' then
          style = (CIRCUITS[sess.level] and loose / g.n < 0.25) and 'circuit' or 'rally'
        end
        local st = STYLE[style]
        betterLine(g, car, st)
        clipFixes = clipFixes + g.clipFixes
        local lim = carModel(seg, car, options.margin)
        balanceOf(g, lim)
        idealSpeeds(g, lim)
        if g.n > modelLen then model, modelLen = { lim = lim, style = style, loose = loose / g.n, gain = g.steerGain }, g.n end
        local corners = findCorners(g)
        local prevExit
        for _, c in ipairs(corners) do
          judgeCorner(g, seg, lim, st, car, c, prevExit)
          prevExit = c.exit
          cid = cid + 1
          local off = #pts.s
          out.corners[#out.corners + 1] = {
            id = cid, dir = c.dir, radius = c.radius, unneeded = c.unneeded or nil, incident = c.incident,
            loss = round(c.loss, 2), note = c.note,
            i0 = off + max(1, c.s0 - 12), i1 = off + min(g.n, c.exit + 4),
            iBrakeIdeal = off + c.s0, iApex = off + c.apex, iPickup = off + c.pickup, iExit = off + c.exit,
            iBrake = c.brakeIdx and off + c.brakeIdx or nil, iThrottle = c.throttleIdx and off + c.throttleIdx or nil,
            iMin = off + c.minIdx,
            gradePct = (function()
              local sum, cnt = 0, 0
              for k = c.s0, c.apex do sum, cnt = sum + (g.grade[k] or 0), cnt + 1 end
              return cnt > 0 and round(sum / cnt * 100) or 0
            end)(),
            minSpeed = round(c.minSpeed, 1), idealMin = round(c.idealMin, 1),
            exitSpeed = round(c.exitSpeed, 1), idealExit = round(c.idealExit, 1),
            brakeDiff = c.brakeDiff and round(c.brakeDiff), brakePeak = c.brakePeak and round(c.brakePeak, 2),
            brakeRise = c.brakeRise and round(c.brakeRise, 2), coast = c.coast and round(c.coast, 2),
            throttleLateS = c.throttleLateS and round(c.throttleLateS, 2), apexGap = c.apexGap and round(c.apexGap, 1),
            sawRate = round(c.sawRate or 0, 1), gripUse = round(c.gripUse or 0, 2), trail = c.trail,
            keys = {}, good = {}, goodKeys = {}, tStart = g.t[max(1, c.s0 - 12)], tEnd = g.t[min(g.n, c.exit + 4)],
            hasReplay = findPart(sess, g.t[max(1, c.s0 - 12)] - 3) ~= nil,
            balance = (function() -- the car's balance through the corner, in a few words
              local function count(a, b, kind)
                local m = 0
                for k = max(1, a), min(g.n, b) do if g.bal[k] == kind then m = m + 1 end end
                return m
              end
              local uIn, oIn = count(c.s0, c.apex, 1), count(c.s0, c.apex, 2)
              local uOut, oOut = count(c.apex + 1, c.exit, 1), count(c.apex + 1, c.exit, 2)
              local parts = {}
              if uIn >= 2 then parts[#parts + 1] = 'pushed wide on entry' end
              if oIn >= 2 then parts[#parts + 1] = 'rear stepped out on entry' end
              if uOut >= 2 then parts[#parts + 1] = 'pushed wide on exit' end
              if oOut >= 2 then parts[#parts + 1] = 'rear stepped out on exit' end
              return #parts > 0 and table.concat(parts, ', ') or nil
            end)(),
          }
          local oc = out.corners[#out.corners]
          for _, f in ipairs(c.findings) do table.insert(oc.keys, f.key) end
          for k, gd in ipairs(c.good) do
            table.insert(oc.goodKeys, gd.key)
            if k <= 2 then table.insert(oc.good, gd.text) end
          end
        end
        for k = 1, g.n do
          -- the drivable band: road edges (or your line off the graph), closed in by walls
          local el = g.known[k] and g.roadL[k] or g.alphaDrv[k] + 1
          local er = g.known[k] and g.roadR[k] or g.alphaDrv[k] - 1
          if g.wallL[k] then el = max(min(el, g.wallL[k]), g.alphaDrv[k]) end
          if g.wallR[k] then er = min(max(er, g.wallR[k]), g.alphaDrv[k]) end
          local i = #pts.s + 1
          pts.s[i] = round(sOff + (k - 1) * DS)
          pts.x[i], pts.y[i] = round(g.x[k], 1), round(g.y[k], 1)
          pts.ix[i], pts.iy[i] = round(g.ix[k], 1), round(g.iy[k], 1)
          pts.lx[i], pts.ly[i] = round(g.cx[k] + el * g.nx[k], 1), round(g.cy[k] + el * g.ny[k], 1)
          pts.rx[i], pts.ry[i] = round(g.cx[k] + er * g.nx[k], 1), round(g.cy[k] + er * g.ny[k], 1)
          pts.v[i], pts.iv[i] = round(g.v[k], 2), round(g.iv[k], 2)
          pts.ib[i], pts.it[i] = round(g.ib[k], 3), round(g.it[k], 3)
          pts.d[i] = round(dOff + g.delta[k], 3)
          pts.t[i] = round(g.t[k], 3)
          pts.seg[i] = si
          pts.bal[i] = g.bal[k]
        end
        -- raw samples for the charts, one every TRACE_DS metres or TRACE_DT seconds
        local lastS, lastT = -huge, -huge
        local total = (g.n - 1) * DS
        for i, smp in ipairs(seg) do
          local d = seg.dist[i]
          if d > total then break end
          if d - lastS >= TRACE_DS or smp[T] - lastT >= TRACE_DT then
            lastS, lastT = d, smp[T]
            local j = #tr.s + 1
            tr.s[j] = round(sOff + d, 1)
            tr.v[j], tr.thr[j], tr.brk[j], tr.bp[j] = round(smp[SPD], 2), round(smp[THR], 2), round(smp[BRK], 2), round(smp[BP], 2)
            tr.str[j], tr.gear[j], tr.rpm[j] = round(smp[STR], 3), smp[GEAR], round(smp[RPM])
            tr.lat[j] = round(smp[LAT] / G, 2)
            tr.seg[j] = si
          end
        end
        out.tDrive = out.tDrive + (g.t[g.n] - g.t[1])
        out.tIdeal = out.tIdeal + g.tI[g.n]
        sOff = sOff + g.n * DS
        dOff = dOff + g.delta[g.n]
      end
    end
  end
  out.points = pts
  out.n = #pts.s
  out.trace = tr
  if model then
    local lim = model.lim
    local main = lim.main
    local surfaces = {}
    for cl = 1, 5 do
      if lim.measured[cl] or cl == main then
        surfaces[#surfaces + 1] = { name = SURF_NAME[cl], g = round(lim.mu[cl] / G, 2), measured = lim.measured[cl] or nil }
      end
    end
    out.limits = { lat = round(lim.latAt(main, 0) / G, 2), brk = round(lim.brkAt(main, 0) / G, 2) }
    out.model = {
      margin = options.margin, style = model.style, styleSetting = options.style,
      surface = SURF_NAME[main], lat = round(lim.mu[main] / G, 2), brk = round(lim.brakeShare * lim.mu[main] / G, 2),
      aeroAt150 = round(lim.loadAt(150 / 3.6) - 1, 2), corners = lim.events, surfaces = surfaces,
      brakeCap = lim.brakeCap and round(lim.brakeCap / G, 2) or nil,
      powerKW = car.powerKW and car.powerKW > 0 and round(car.powerKW) or nil, mass = car.mass and car.mass > 0 and round(car.mass) or nil,
      powerMeasuredKW = lim.measuredW and round(lim.measuredW / 1000) or nil, powerMeasuredKmh = lim.measuredV and round(lim.measuredV * 3.6) or nil,
      steerGain = model.gain and round(model.gain, 4) or nil, -- curvature (1/m) per unit of steering; nil = understeer not judged
      driven = car.driven ~= '' and car.driven or nil, abs = car.abs, walls = rayed, clipFixes = clipFixes,
    }
  end

  -- after a crash, spin or off you usually drive on slowly (often with a damaged car): later
  -- corners well under pace count as part of that incident until you are back on pace
  local after, afterUntil
  for _, c in ipairs(out.corners) do
    if c.incident and c.incident ~= 'after' and c.incident ~= 'lost' then
      after, afterUntil = c.id, c.tEnd + 60
    elseif after and not c.incident then
      local pace = c.idealMin > 0 and c.minSpeed / c.idealMin or 1
      if c.tStart > afterUntil or pace >= 0.85 then
        after = nil
      elseif pace < 0.75 and not c.unneeded then
        c.incident, c.keys, c.good, c.goodKeys = 'after', {}, {}, {}
        c.note = string.format('Slow after the incident at corner %d: not counted in the tips or the clean gap.', after)
      end
    end
  end

  -- ranking and habit tips
  local ranked = {}
  for _, c in ipairs(out.corners) do ranked[#ranked + 1] = c end
  table.sort(ranked, function(a, b) return a.loss > b.loss end)
  out.order = {}
  for i, c in ipairs(ranked) do out.order[i] = c.id end
  local byKey = {}
  for _, c in ipairs(out.corners) do
    for rank, key in ipairs(c.keys) do
      if rank <= 3 then
        local e = byKey[key] or { key = key, w = 0, ids = {} }
        e.w = e.w + max(c.loss, 0.05) / rank
        table.insert(e.ids, c.id)
        byKey[key] = e
      end
    end
  end
  local tips = {}
  for _, e in pairs(byKey) do tips[#tips + 1] = e end
  table.sort(tips, function(a, b) return a.w > b.w end)
  out.tips = {}
  for i = 1, min(2, #tips) do
    local e = tips[i]
    local ids = {}
    for j = 1, min(5, #e.ids) do ids[j] = e.ids[j] end
    out.tips[i] = { key = e.key, text = TIPS[e.key] or e.key, corners = ids }
  end
  -- strengths: positives that showed up at least twice (once on a short drive), with where
  local count, where = {}, {}
  for _, c in ipairs(out.corners) do
    for _, key in ipairs(c.goodKeys) do
      count[key] = (count[key] or 0) + 1
      where[key] = where[key] or {}
      if #where[key] < 5 then table.insert(where[key], c.id) end
    end
  end
  local strengths = {}
  for rank, key in ipairs(STRENGTH_ORDER) do
    if (count[key] or 0) >= (#out.corners >= 6 and 2 or 1) then strengths[#strengths + 1] = { key = key, n = count[key], rank = rank } end
  end
  -- most important first (STRENGTH_ORDER), so common small things don't crowd out the big ones
  out.strengths = {}
  for i = 1, min(3, #strengths) do
    local e = strengths[i]
    out.strengths[i] = { key = e.key, text = string.format(STRENGTHS[e.key], e.n), corners = where[e.key] }
  end
  local lossTop = 0
  for i = 1, min(3, #ranked) do lossTop = lossTop + max(ranked[i].loss, 0) end
  out.tDrive, out.tIdeal = round(out.tDrive, 1), round(out.tIdeal, 1)
  out.gap = round(out.tDrive - out.tIdeal, 1)
  -- the gap without the time lost in incidents
  local incidents, incLoss = 0, 0
  for _, c in ipairs(out.corners) do
    if c.incident then incidents, incLoss = incidents + 1, incLoss + max(c.loss, 0) end
  end
  out.incidents = incidents
  out.gapClean = incidents > 0 and round(max(out.gap - incLoss, 0), 1) or nil
  out.top3 = round(lossTop, 1)
  out.date, out.level, out.car, out.session = sess.date, sess.level, sess.model, sess.name
  out.hasReplay = false -- any replay file left for this session
  for _, part in ipairs(sess.parts or {}) do
    if partOk(part) then out.hasReplay = true end
  end
  out.unit = settings.getValue('uiUnitLength') == 'imperial' and 'mph' or 'km/h'
  local okLaps, laps = pcall(lapAnalysis, out, sess)
  if okLaps then out.laps = laps else log('W', logTag, 'lap analysis failed: ' .. tostring(laps)) end
  return out
end

-- ui -------------------------------------------------------------------------

local function sendState()
  local st = {
    open = panelOpen, mode = replay and 'replay' or 'review',
    recording = rec and { secs = floor(rec.samples[#rec.samples] and rec.samples[#rec.samples][T] or 0), dist = floor(rec.dist),
      replay = rec.replayFile ~= nil, armed = rec.armed or nil } or nil,
    recordReplay = options.recordReplay, replayFiles = replayUsage(),
    hasResult = result ~= nil,
  }
  if replay then
    st.replay = { t = replay.t, paused = replay.paused, speed = replay.speed, corner = replay.corner, ready = replay.ready, msg = replay.msg }
  end
  guihooks.trigger('CoDriverAnalysisState', st)
end

local function sendData()
  guihooks.trigger('CoDriverAnalysisData', result or {})
end

-- session files and the archive ------------------------------------------------

-- The session as saved: only the recorded fields (analysis appends some to a few samples only,
-- and a table with gaps would be written as an object with string keys).
local function sessionFile(sess)
  local nf = (sess.fmt or 1) >= 2 and SURF or WS
  local raw = {}
  for i, smp in ipairs(sess.samples) do
    local r = {}
    for f = 1, nf do r[f] = smp[f] or 0 end
    raw[i] = r
  end
  return { date = sess.date, stamp = sess.stamp, level = sess.level, model = sess.model, parts = sess.parts,
    fmt = sess.fmt, car = sess.car, laps = sess.laps, samples = raw }
end

-- A loaded session file, normalised: recorded fields only (17 for 20 Hz sessions), numeric
-- keys (older saves could hold analysis fields, or gaps that came back as string keys).
local function readSession(path)
  local s = FS:fileExists(path) and jsonReadFile(path)
  if type(s) ~= 'table' or type(s.samples) ~= 'table' then return nil end
  s.parts = type(s.parts) == 'table' and s.parts or {}
  s.fmt = tonumber(s.fmt) or 1 -- a damaged file can't make the analysis throw before its own guard
  local nf = s.fmt >= 2 and SURF or WS
  for i, smp in ipairs(s.samples) do
    local r = {}
    for f = 1, nf do r[f] = tonumber(smp[f] or smp[tostring(f)]) or 0 end
    s.samples[i] = r
  end
  return s
end

readIndex = function()
  local idx = FS:fileExists(SESS_INDEX) and jsonReadFile(SESS_INDEX)
  return type(idx) == 'table' and idx or {}
end

-- Duration and driven distance (2D, teleports left out).
local function sessionSize(sess)
  local d, smp = 0, sess.samples
  for i = 2, #smp do
    local s = sqrt((smp[i][X] - smp[i - 1][X]) ^ 2 + (smp[i][Y] - smp[i - 1][Y]) ^ 2)
    if s < 30 then d = d + s end
  end
  return (#smp > 0 and smp[#smp][T] - smp[1][T] or 0), d
end

-- Archive name: start time, level and car, e.g. 20261018_142551_italy_covet.
local function archiveName(sess)
  local stamp = sess.stamp or tostring(sess.date or ''):gsub('[^%d]', ''):gsub('^(%d%d%d%d%d%d%d%d)', '%1_')
  local name = stamp .. '_' .. tostring(sess.level or '') .. '_' .. tostring(sess.model or '')
  return (name:gsub('[^%w_%-]', ''))
end

-- Saves a session as the last session and into the archive (every session of a minute or
-- 500 m and more; nothing is deleted automatically). With onlyArchive it is not written over last_session.json.
saveSession = function(sess, onlyArchive)
  if not FS:directoryExists(SESS_DIR) then FS:directoryCreate(SESS_DIR, true) end
  local ok, js = pcall(jsonEncode, sessionFile(sess)) -- encoded once, written to both files
  if not ok then return end
  if not onlyArchive then pcall(writeFile, SAVE_PATH, js) end
  local secs, dist = sessionSize(sess)
  if secs < SESS_MIN_SECS or dist < SESS_MIN_M then return end
  local name = archiveName(sess)
  sess.name = name
  pcall(writeFile, SESS_DIR .. name .. '.json', js)
  -- index, newest first
  local idx, out = readIndex(), {}
  local replays = {}
  for _, part in ipairs(sess.parts or {}) do replays[#replays + 1] = part.file end
  local nLaps, bestLap = 0, nil
  for _, l in ipairs(sess.laps or {}) do
    if not l.partial then nLaps = nLaps + 1 end
    if l.valid and (not bestLap or l.time < bestLap) then bestLap = l.time end
  end
  out[1] = { name = name, date = sess.date, level = sess.level, model = sess.model, secs = floor(secs), km = round(dist / 1000, 1), fmt = sess.fmt or 1, replays = replays,
    laps = nLaps > 0 and nLaps or nil, bestLap = bestLap }
  for _, e in ipairs(idx) do
    if type(e) == 'table' and e.name ~= name and FS:fileExists(SESS_DIR .. tostring(e.name) .. '.json') then out[#out + 1] = e end
  end
  table.sort(out, function(a, b) return tostring(a.name) > tostring(b.name) end)
  pcall(jsonWriteFile, SESS_INDEX, out, true)
end

local function listSessions()
  local out = {}
  for _, e in ipairs(readIndex()) do
    if type(e) == 'table' and FS:fileExists(SESS_DIR .. tostring(e.name) .. '.json') then out[#out + 1] = e end
  end
  return out
end

-- Personal bests across sessions (Phase D) --------------------------------------------
-- Each route's best lap is kept as a small file, settings/coDriverCoach/routes/<level>_best/<route>.json:
-- 4 m points (position, lap time, speed, throttle, brake) from that lap's telemetry. It is written
-- when a lap sets the route's best, and made once from the archived session holding an older best
-- (ensureBestEver, which coDriverLaps calls after a level loads), so a review can compare with the
-- best ever and the lap timer can show a ghost.
do
  local BEST_DIR = 'settings/coDriverCoach/routes/'
  local function bestEverPath(lvl, route)
    return BEST_DIR .. tostring(lvl) .. '_best/' .. (tostring(route):gsub('[^%w_%-]', '_')) .. '.json'
  end
  M.bestEverPath = bestEverPath

  -- 4 m points of samples t0..t1 (session time); nil if the lap has a jump in it or is too short
  local function bestFromSamples(samples, t0, t1)
    local pts = { x = {}, y = {}, z = {}, t = {}, v = {}, thr = {}, brk = {} }
    local prev, dist, nextAt, firstT = nil, 0, 0, nil
    for _, smp in ipairs(samples) do
      local t = smp[T]
      if t > t1 + 0.05 then break end
      if t >= t0 then
        firstT = firstT or t
        if prev then
          local d = sqrt((smp[X] - prev[X]) ^ 2 + (smp[Y] - prev[Y]) ^ 2)
          if d > 30 then return nil end
          while d > 0 and dist + d >= nextAt do
            local f = (nextAt - dist) / d
            local k = #pts.x + 1
            local function lerp(fld) return prev[fld] + (smp[fld] - prev[fld]) * f end
            pts.x[k], pts.y[k], pts.z[k] = round(lerp(X), 2), round(lerp(Y), 2), round(lerp(Z), 2)
            pts.t[k] = round(max(0, lerp(T) - t0), 3)
            pts.v[k] = round(sqrt(lerp(VX) ^ 2 + lerp(VY) ^ 2), 2)
            pts.thr[k], pts.brk[k] = round(lerp(THR), 2), round(lerp(BRK), 2)
            nextAt = nextAt + 4
          end
          dist = dist + d
        end
        prev = smp
      end
    end
    if not firstT or firstT > t0 + 0.5 or not prev or prev[T] < t1 - 0.5 then return nil end -- not the whole lap
    return #pts.x >= 25 and pts or nil
  end

  M.loadBestEver = function(lvl, route)
    local p = lvl and route and bestEverPath(lvl, route)
    local d = p and FS:fileExists(p) and jsonReadFile(p)
    if type(d) ~= 'table' or type(d.pts) ~= 'table' or type(d.pts.x) ~= 'table' or #d.pts.x < 25 then return nil end
    return d
  end

  M.saveBestEver = function(lvl, route, lap, samples, sessName, car, date)
    local pts = bestFromSamples(samples, lap.t0, lap.t1)
    if not pts then return false end
    local p = bestEverPath(lvl, route)
    local dir = p:match('^(.*)/')
    if not FS:directoryExists(dir) then FS:directoryCreate(dir, true) end
    jsonWriteFile(p, { version = 1, level = lvl, route = route, time = lap.time, date = date or os.date('%Y-%m-%d %H:%M'),
      session = sessName, car = car, pts = pts }, false)
    log('I', logTag, string.format('best lap on %s kept for comparisons and the ghost (%.3f s, %d points)', tostring(route), lap.time or 0, #pts.x))
    if coDriverLaps and coDriverLaps.bestChanged then pcall(coDriverLaps.bestChanged, route) end
    return true
  end

  -- the recording's new best, once samples up to its finish have arrived (or now, when forced)
  M._flushBest = function(force)
    local pb = rec and rec.pendingBest
    if not pb then return end
    local last = rec.samples[#rec.samples]
    if not force and (not last or last[T] < pb.t1 + 0.3) then return end
    rec.pendingBest = nil
    local name = archiveName(rec)
    local ok, err = pcall(M.saveBestEver, pb.level, pb.route, pb, rec.samples, name, rec.model)
    if not ok then log('W', logTag, 'keeping the best lap failed: ' .. tostring(err)) end
  end

  -- make the file from the archived session that holds a route's best, if it's missing or older
  M.ensureBestEver = function(lvl, route, bestTime)
    bestTime = tonumber(bestTime)
    if not (lvl and route and bestTime) then return false end
    local have = M.loadBestEver(lvl, route)
    if have and tonumber(have.time) and tonumber(have.time) <= bestTime + 0.005 then return true end
    for _, e in ipairs(readIndex()) do
      if type(e) == 'table' and e.level == lvl and tonumber(e.bestLap) and abs(e.bestLap - bestTime) < 0.006 then
        local s = readSession(SESS_DIR .. tostring(e.name) .. '.json')
        for _, lap in ipairs(s and type(s.laps) == 'table' and s.laps or {}) do
          if lap.route == route and lap.valid and abs((tonumber(lap.time) or 0) - bestTime) < 0.006 then
            return M.saveBestEver(lvl, route, lap, s.samples, e.name, e.model, e.date)
          end
        end
      end
    end
    return false
  end
end

local function runAnalysis()
  if not lastSession then return false end
  local ok, out = xpcall(analyzeSession, debug.traceback, lastSession)
  if not ok then
    log('E', logTag, 'analysis failed: ' .. tostring(out))
    result = { error = 'Analysis failed. Details are in beamng.log.' }
    return false
  end
  result = out
  log('I', logTag, string.format('analysed %d points, %d corners, gap %.1f s', out.n, #out.corners, out.gap or 0))
  return true
end

local function loadOptions()
  noteGameVersion()
  local o = FS:fileExists(OPTIONS_PATH) and jsonReadFile(OPTIONS_PATH)
  if type(o) ~= 'table' then return end
  if tonumber(o.margin) then options.margin = clamp(tonumber(o.margin), 0.8, 1) end
  if o.style == 'rally' or o.style == 'circuit' or o.style == 'auto' then options.style = o.style end
  if REPLAY_MODES[o.recordReplay] then options.recordReplay = o.recordReplay end
end

local function openPanel()
  panelOpen = true
  sendData()
  sendState()
end

local function closePanel()
  panelOpen = false
  sendState()
end

-- End of session: stop recording, analyse and open the review.
local function review()
  local sess = endSession()
  if not sess then
    result = { error = 'Nothing recorded yet. Drive with the coach on and the recording starts by itself.' }
  else
    runAnalysis() -- endSession has saved it
  end
  if coDriverCoach and coDriverCoach.dismissSummary then coDriverCoach.dismissSummary() end
  openPanel()
end

-- Model settings from the panel: margin (share of the limit, 0.8..1) or style (auto/rally/circuit).
-- Saved, and the analysis is re-run with them.
local function setOption(key, value)
  if key == 'margin' and tonumber(value) then options.margin = clamp(tonumber(value), 0.8, 1)
  elseif key == 'style' and (STYLE[value] or value == 'auto') then options.style = value
  elseif key == 'recordReplay' and REPLAY_MODES[value] then
    options.recordReplay = value
    if not FS:directoryExists('settings/coDriverCoach') then FS:directoryCreate('settings/coDriverCoach', true) end
    pcall(jsonWriteFile, OPTIONS_PATH, options, true)
    sendState()
    return -- no re-analysis needed
  else return end
  if not FS:directoryExists('settings/coDriverCoach') then FS:directoryCreate('settings/coDriverCoach', true) end
  pcall(jsonWriteFile, OPTIONS_PATH, options, true)
  if lastSession then
    runAnalysis()
    if panelOpen then sendData() end
  end
end

-- Re-analyse the last saved session (after a game restart, or for testing). A session saved
-- by an older version that isn't archived yet goes into the archive too.
local function loadLast()
  local s = readSession(SAVE_PATH)
  if not s then return false end
  if not FS:fileExists(SESS_DIR .. archiveName(s) .. '.json') then saveSession(s, true) end
  s.name = s.name or archiveName(s)
  lastSession = s
  return runAnalysis()
end

-- Opens an archived session by name (as listSessions gives it) or by a path to a session file.
local function loadSession(name)
  name = tostring(name or '')
  local path = name:find('/', 1, true) and name or (SESS_DIR .. name:gsub('%.json$', '') .. '.json')
  local s = readSession(path)
  if not s then
    log('W', logTag, 'no session file ' .. path)
    return false
  end
  s.name = s.name or (name:find('/', 1, true) and archiveName(s) or name:gsub('%.json$', ''))
  lastSession = s
  local ok = runAnalysis()
  openPanel()
  return ok
end

-- replay ---------------------------------------------------------------------

local function findCorner(id)
  for _, c in ipairs(result and result.corners or {}) do if c.id == id then return c end end
end

local function replayTimeToSession(t) return t - (replay and replay.offset or 0) end
local function sessionToReplayTime(t) return t + (replay and replay.offset or 0) end

local function seekSession(t)
  if not replay or not replay.ready then return end
  local total = core_replay.getTotalSeconds and core_replay.getTotalSeconds() or 0
  if total <= 0 then return end
  core_replay.seek(clamp(sessionToReplayTime(t) / total, 0, 0.9999))
  replay.t, replay.seekT, replay.seekAt = t, t, clock -- updates from before the seek may still arrive
end

-- The replay plays the drive continuously from wherever you start it: the better line and the
-- markers of each turn follow the car, prev/next jump turn to turn within the same playback, and
-- the 5-minute replay files hand over to each other (gaps in the recording are skipped, with a note).

-- Index of the replay part holding session time t (its file must exist), or nil.
local function partIndexAt(t, any)
  local found
  for i, part in ipairs(lastSession and lastSession.parts or {}) do
    if part.t0 <= t + 0.5 then found = i end
  end
  local part = found and lastSession.parts[found]
  if part and (any or partOk(part)) then return found end
end

-- The first playable part starting after session time t.
local function nextPlayable(t)
  for i, part in ipairs(lastSession and lastSession.parts or {}) do
    if part.t0 > t + 0.5 and partOk(part) then return i end
  end
end

-- m:ss from the start of the session.
local function clockText(t)
  local first = lastSession and lastSession.samples[1]
  t = max(0, t - (first and first[T] or 0))
  local m = floor(t / 60)
  return string.format('%d:%02d', m, floor(t - m * 60))
end

local function partRangeText(i)
  local parts = lastSession.parts
  local a = parts[i].t0
  local b = parts[i + 1] and parts[i + 1].t0 or lastSampleT(lastSession)
  return clockText(a) .. '–' .. clockText(b)
end

-- After a part turns out to be damaged: the replay buttons follow what can still be played.
local function refreshReplayFlags()
  if not result or not result.corners then return end
  result.hasReplay = false
  for _, part in ipairs(lastSession.parts or {}) do
    if partOk(part) then result.hasReplay = true end
  end
  for _, c in ipairs(result.corners) do c.hasReplay = findPart(lastSession, (c.tStart or 0) - 3) ~= nil end
  if panelOpen then sendData() end
end

-- Corners in turn order (ids are in drive order).
local function cornersInOrder()
  local cs = {}
  for _, c in ipairs(result and result.corners or {}) do cs[#cs + 1] = c end
  table.sort(cs, function(a, b) return a.tStart < b.tStart end)
  return cs
end

-- The turn at session time t: the last one whose approach (3 s before its brake point) has
-- started, or the first one before any has.
local function activeCorner(t)
  local cs = cornersInOrder()
  local found = cs[1]
  for _, c in ipairs(cs) do
    if c.tStart - 3 <= t + 0.05 then found = c end
  end
  return found
end

local function setReplayMsg(text, secs)
  if not replay then return end
  replay.msg, replay.msgUntil = text, secs and clock + secs or nil
end

local exitReplay -- defined below

-- Plays from session time t: a seek when that moment is in the file already loaded, otherwise
-- the file holding it is loaded (on its first state update onReplayStateChanged seeks to t).
-- Why a part can't play: recorded by an older game version, or damaged.
local function badText(i)
  local part = lastSession and lastSession.parts[i]
  local key = part and tostring(part.file):lower()
  if part and (not partVersionOk(part) or (damaged and damaged[key] == 'version')) then
    return 'The replay for ' .. partRangeText(i) .. ' was recorded with an older BeamNG version, which this version cannot play'
  end
  return 'The replay for ' .. partRangeText(i) .. ' is damaged'
end
local function unplayable(i)
  local part = lastSession and lastSession.parts[i]
  return part and FS:fileExists(part.file) and not partOk(part)
end

local loadFailed -- defined after playFrom

local function playFrom(t)
  if not result or not lastSession then return false end
  local idx = partIndexAt(t)
  if not idx then
    local bad, nxt = partIndexAt(t, true), nextPlayable(t)
    if bad and nxt and unplayable(bad) then
      -- inside a part that can't play: carry on from the next one that plays
      idx, t = nxt, lastSession.parts[nxt].t0
      if replay then setReplayMsg(badText(bad) .. ': skipped', 5) end
    else
      guihooks.message(bad and unplayable(bad) and (badText(bad) .. '.')
        or 'No replay for this part of the drive (only the latest drives keep their replays, and missions or other replays pause the recorder).', 7, 'coDriverAnalysis')
      if replay and not replay.ready then exitReplay() end
      return false
    end
  end
  local part = lastSession.parts[idx]
  t = max(t, part.t0)
  if not replay then
    local veh = getPlayerVehicle(0)
    replay = {
      speed = 1, cam = core_camera.getActiveCamName(0), zc = {},
      pose = veh and { pos = vec3(veh:getPosition()), rot = quat(veh:getRotation()), id = veh:getId() } or nil,
    }
  end
  replay.part = idx
  if replay.file == part.file and replay.ready then
    seekSession(t)
    core_replay.pause(false)
    replay.paused = false
  else
    replay.file, replay.offset, replay.ready, replay.paused = part.file, (part.offset or 0), false, false
    replay.startT, replay.t, replay.loadT = t, t, clock
    if not replay.msgUntil then setReplayMsg(replay.everLoaded and 'Next replay file...' or 'Loading replay...') end
    -- (0.39 loads at once and can fail here; 0.40 queues the load, so a refusal shows up in
    -- updateReplay as nothing playing)
    local res = core_replay.loadFile(part.file, true)
    if type(res) == 'table' and res.success == false then return loadFailed(idx, part, t, res.message) end
  end
  local c = activeCorner(t)
  replay.corner = c and c.id or nil
  sendState()
  return true
end

-- Plays from a turn (a few seconds before its ideal brake point), or from t0 when id is nil.
local function replayCorner(id, t0)
  local c = id and findCorner(id)
  playFrom(c and c.tStart - 3 or (t0 or 0))
end

-- Next or previous turn within the playback. Previous restarts the current turn when you are
-- more than 2 s into it, like a media player.
local function replayStep(dir)
  if not replay then return end
  local t = replay.t or 0
  local cs = cornersInOrder()
  local cur = activeCorner(t)
  local k = 0
  for i, c in ipairs(cs) do if c == cur then k = i end end
  if cur and cur.tStart - 3 > t then k = k - 1 end -- before the first turn's approach
  local target
  if dir > 0 then
    target = cs[k + 1]
  elseif cur and k >= 1 and t - (cs[k].tStart - 3) > 2 then
    target = cs[k] -- back to the start of this turn
  else
    target = cs[max(1, k - 1)]
  end
  if target then playFrom(target.tStart - 3) end
end

-- A replay file that didn't load. The two unreadable files seen in 0.39 had both been loaded while
-- the replay engine was busy, so a file of this game version gets one more try once the engine is
-- idle; then it is remembered (damaged, or from another version) and playback goes on with the
-- next part that plays.
loadFailed = function(idx, part, t, why)
  if not replay then return false end
  local sameVersion = partVersionOk(part)
  if sameVersion and not (replay.retried and replay.retried[part.file]) then
    replay.retried = replay.retried or {}
    replay.retried[part.file] = true
    log('W', logTag, 'replay file failed to load, retrying once: ' .. tostring(part.file) .. ' ' .. tostring(why))
    replay.file = nil
    replay.pendingSwitch = { t = t, at = clock + 1.0 }
    pcall(core_replay.stop)
    return true
  end
  log('W', logTag, 'replay file failed to load: ' .. tostring(part.file) .. ' ' .. tostring(why))
  markDamaged(part.file, not sameVersion and 'version' or true)
  replay.file = nil
  refreshReplayFlags()
  local msg = badText(idx)
  local nxt = nextPlayable(part.t0)
  if nxt then
    setReplayMsg(msg .. ': skipped', 5)
    return playFrom(lastSession.parts[nxt].t0)
  end
  guihooks.message(msg .. '.', 7, 'coDriverAnalysis')
  exitReplay()
  return false
end

local function onReplayStateChanged(st)
  if not replay then return end
  if st.state == 'playback' and (st.totalSeconds or 0) > 0 then
    replay.total = st.totalSeconds
    if not replay.ready then
      replay.ready, replay.everLoaded = true, true
      if not replay.msgUntil then replay.msg = nil end
      core_camera.setByName(0, 'orbit')
      seekSession(replay.startT)
      core_replay.setSpeed(replay.speed)
      core_replay.pause(replay.paused)
    else
      local t = replayTimeToSession(st.positionSeconds or 0)
      local stale = replay.seekAt and clock - replay.seekAt < 0.5 and abs(t - replay.seekT) > 1
      if not stale then replay.t = t end
    end
    replay.paused = st.paused
  end
end

local function setReplaySpeed(x)
  if not replay then return end
  replay.speed = x
  core_replay.setSpeed(x)
  sendState()
end

local function setReplayPaused(p)
  if not replay or not replay.ready then return end
  if not p and replay.atEnd then
    replay.atEnd = nil
    local first = lastSession.parts[1]
    if first then return playFrom(first.t0) end
  end
  core_replay.pause(p)
  replay.paused = p
  sendState()
end

exitReplay = function()
  if not replay then return end
  local r = replay
  replay = nil
  pcall(core_replay.stop)
  local veh = getPlayerVehicle(0)
  if veh and r.pose then
    -- safeTeleport turns the given rotation by quat(0, 0, 1, 0); undo that so the car faces as before
    pcall(spawn.safeTeleport, veh, r.pose.pos, r.pose.rot * quat(0, 0, -1, 0))
  end
  if r.cam then pcall(core_camera.setByName, 0, r.cam) end
  sendState()
end

-- First grid index at or after session time t.
local function gridAtT(t)
  local p = result.points
  local lo, hi = 1, #p.t
  while lo < hi do
    local mid = floor((lo + hi) / 2)
    if p.t[mid] < t then lo = mid + 1 else hi = mid end
  end
  return lo
end

-- The better line ahead of the car and your line behind it, plus the markers of the turns
-- around it (each fades in about 6 s before its brake point and out 2.5 s after the exit).
local function drawReplay()
  if not replay or not replay.ready or not result or not result.points then return end
  local p = result.points
  local samples = lastSession.samples
  local zc = replay.zc
  local function zAt(i)
    if zc[i] then return zc[i] end
    local t = p.t[i]
    local lo, hi = 1, #samples
    while hi - lo > 1 do
      local mid = floor((lo + hi) / 2)
      if samples[mid][T] < t then lo = mid else hi = mid end
    end
    zc[i] = samples[lo][Z] + 0.15
    return zc[i]
  end
  local t = replay.t or 0
  local now = gridAtT(t)
  local green, orange = ColorF(0.3, 1, 0.45, 0.8), ColorF(1, 0.6, 0.15, 0.75)
  for i = max(1, now - 8), min(result.n - 1, now + 40) do -- about 30 m behind to 160 m ahead
    if p.seg[i] == p.seg[i + 1] then
      debugDrawer:drawSquarePrism(vec3(p.ix[i], p.iy[i], zAt(i)), vec3(p.ix[i + 1], p.iy[i + 1], zAt(i + 1)), Point2F(0.04, 0.5), Point2F(0.04, 0.5), green)
    end
  end
  for i = max(1, now - 40), min(result.n - 1, now) do -- your line, the last 160 m
    if p.seg[i] == p.seg[i + 1] then
      debugDrawer:drawSquarePrism(vec3(p.x[i], p.y[i], zAt(i) + 0.02), vec3(p.x[i + 1], p.y[i + 1], zAt(i + 1) + 0.02), Point2F(0.04, 0.3), Point2F(0.04, 0.3), orange)
    end
  end
  for _, c in ipairs(result.corners) do
    local a = min(clamp((t - (c.tStart - 6)) / 2, 0, 1), clamp(1 - (t - c.tEnd) / 2.5, 0, 1))
    if a > 0.02 then
      local function mark(i, ideal, text, r, g, b)
        if not i then return end
        local pos = ideal and vec3(p.ix[i], p.iy[i], zAt(i) + 0.4) or vec3(p.x[i], p.y[i], zAt(i) + 0.4)
        debugDrawer:drawSphere(pos, 0.35, ColorF(r, g, b, 0.9 * a))
        -- your own marker's label sits lower, so it doesn't overlap the ideal ones
        debugDrawer:drawTextAdvanced(pos + vec3(0, 0, ideal and 1.0 or 0.45), String(text), ColorF(1, 1, 1, a), true, false, ColorI(0, 0, 0, floor(170 * a)))
      end
      mark(c.iBrakeIdeal, true, c.unneeded and 'NO BRAKE NEEDED' or 'BRAKE HERE', 1, 0.25, 0.2)
      mark(c.iBrake, false, 'you braked', 1, 0.6, 0.15)
      if not c.unneeded then
        mark(c.iApex, true, 'APEX ' .. c.id, 0.3, 1, 0.45)
        mark(c.iPickup, true, 'THROTTLE', 0.3, 0.75, 1)
      end
    end
  end
end


-- Keeps the playback going across replay files, notes gaps, and tracks the current turn.
local function updateReplay()
  if not replay then return end
  -- switching files: stop the current playback, wait until the engine is idle, then load
  local sw = replay.pendingSwitch
  if sw then
    if core_replay.getState() ~= 'inactive' then
      if not sw.stopped then sw.stopped = true pcall(core_replay.stop) end
      return
    end
    if clock < sw.at then return end
    replay.pendingSwitch = nil
    playFrom(sw.t)
    return
  end
  if not replay.ready then
    local part = replay.file and lastSession.parts[replay.part or 0]
    if part and part.file == replay.file and clock - replay.loadT > 4 and core_replay.getState() == 'inactive' then
      loadFailed(replay.part, part, replay.startT or part.t0, 'nothing played 4 s after loading')
      return
    end
    if clock - replay.loadT > 15 then
      log('W', logTag, 'replay did not start')
      exitReplay()
      guihooks.message('The replay could not be loaded.', 6, 'coDriverAnalysis')
    end
    return
  end
  if replay.msgUntil and clock > replay.msgUntil then replay.msg, replay.msgUntil = nil, nil end
  local c = activeCorner(replay.t or 0)
  replay.corner = c and c.id or nil
  if replay.paused then return end
  local parts = lastSession.parts
  local part, nextPart = parts[replay.part or 1], parts[(replay.part or 1) + 1]
  local fileEnd = replay.total and (replay.total - (part and part.offset or 0)) or huge -- in session time
  local nearEnd = replay.t >= fileEnd - 0.15
  if nextPart and FS:fileExists(nextPart.file) and (replay.t >= nextPart.t0 or nearEnd) then
    if nextPart.t0 > fileEnd + 1 then
      setReplayMsg(string.format('No recording from %s to %s: skipped', clockText(fileEnd), clockText(nextPart.t0)), 5)
    end
    replay.pendingSwitch = { t = nextPart.t0 + 0.05, at = clock + 0.3 }
  elseif nearEnd or replay.t >= lastSampleT(lastSession) - 0.1 then
    core_replay.pause(true)
    replay.paused, replay.atEnd = true, true
    setReplayMsg(nextPart and 'The rest of the drive has no replay (not recorded in this replay mode, or the file is missing).' or 'End of the recording. Play to start over.')
  end
end

-- main loop ------------------------------------------------------------------

local function onUpdate(dtReal, dtSim)
  clock = clock + dtReal
  updateReplay()
  stateTimer = stateTimer - dtReal
  if stateTimer <= 0 then
    stateTimer = replay and 0.1 or 1
    if panelOpen or replay then sendState() end
  end
  if replay or inForeignReplay() then return end

  local veh = getPlayerVehicle(0)
  if rec then
    if not veh or veh:getId() ~= rec.vid or not coachEnabled() then
      endSession() -- switched car or coach off: keep what was recorded
      return
    end
    updateReplayParts(dtReal, vec3(veh:getVelocity()):length())
    -- vehicle reloaded (its extension is gone): ask it again
    if clock - chunkT > 3 then
      chunkT = clock
      veh:queueLuaCommand('extensions.load("coDriverRec") if coDriverRec and not coDriverRec.isActive() then coDriverRec.start() end')
    end
  elseif veh and coachEnabled() and not panelOpen then
    -- moving for a second, so a teleport or reset frame doesn't start a session
    movingT = vec3(veh:getVelocity()):length() > 3 and movingT + dtReal or 0
    if movingT > 1 then
      movingT = 0
      startSession(veh)
    end
  end
end

local function onPreRender()
  if replay then
    local ok, err = pcall(drawReplay)
    if not ok and not replay.drawErr then
      replay.drawErr = true
      log('E', logTag, 'draw failed: ' .. tostring(err))
    end
  end
end

local function onClientEndMission()
  if replay then replay = nil end
  endSession()
end

-- commands ---------------------------------------------------------------------

M.onUpdate = onUpdate
M.onPreRender = onPreRender
M.onChunk = onChunk
M.onCarInfo = onCarInfo
M.onExtensionLoaded = loadOptions
M.setOption = setOption
-- 'laps' mode before lap recognition: record the replay for the rest of this drive
-- A lap from coDriverLaps (finished, or abandoned and kept): stored with the session, in session time.
M.onLap = function(lap)
  if not rec or type(lap) ~= 'table' then return end
  local off = rec.lapOff or 0
  rec.laps = rec.laps or {}
  table.insert(rec.laps, { route = lap.route, closed = lap.closed, len = lap.len, n = lap.n, time = lap.time,
    valid = lap.valid, reason = lap.reason, partial = lap.partial, best = lap.best, progress = lap.progress,
    t0 = round(lap.t0 + off, 2), t1 = round(lap.t1 + off, 2), gate = lap.gate })
  -- a new best on its route: kept as the route's best ever once its last samples are in (onChunk)
  if lap.best and lap.valid and not lap.partial and lap.route then
    rec.pendingBest = { route = lap.route, t0 = round(lap.t0 + off, 2), t1 = round(lap.t1 + off, 2), time = lap.time, level = rec.level }
  end
end

M.armReplay = function(on)
  if rec then rec.armed = on ~= false end
  sendState()
  return rec ~= nil
end
M.getReplayMode = function() return options.recordReplay end
M.isReplayRecording = function() return rec ~= nil and rec.replayFile ~= nil end
M.getOptions = function() return options end
M.onReplayStateChanged = onReplayStateChanged
M.onClientEndMission = onClientEndMission
M.onExtensionUnloaded = function()
  if replay then exitReplay() end
  endSession() -- saves it, and never leaves the game's recorder running without us
  stopReplayRecording()
end
M.review = review
M.keepRecording = function()
  if coDriverCoach and coDriverCoach.dismissSummary then coDriverCoach.dismissSummary() end
end
M.open = function()
  if not result and lastSession then runAnalysis() end
  if not result and not lastSession then loadLast() end
  openPanel()
end
M.close = function() exitReplay() closePanel() end
M.requestState = function() sendState() if panelOpen then sendData() end end

-- Replay files on disk, and the ones older than a week or a month, for the settings panel. Only
-- the user deletes them (deleteOldReplays, from the panel with a confirming second click); the
-- file being recorded or played is never touched.
local REPLAY_AGES = { week = 7, month = 30 }
local function replayFiles()
  local now, out = os.time(), {}
  for _, p in ipairs(FS:findFiles(REPLAY_DIR, '*.rpl', 0, false, false) or {}) do
    local ok, st = pcall(function() return FS:stat(p) end)
    local key = tostring(p):gsub('^/', ''):lower()
    local busy = (rec and rec.replayFile and rec.replayFile:lower():gsub('^/', '') == key)
      or (replay and core_replay and tostring(core_replay.state and core_replay.state.loadedFile or ''):lower():gsub('^/', '') == key)
    local mt = ok and st and st.modtime or now
    out[#out + 1] = { path = p, size = ok and st and st.filesize or 0, age = now - mt, busy = busy and true or false,
      oldVersion = not versionOk(nil, mt) or (damaged ~= nil and damaged[key] == 'version') }
  end
  return out
end
M.replayStorage = function()
  local s = { n = 0, mb = 0, older = {}, version = majorMinor(rawget(_G, 'beamng_versiond')) }
  for k in pairs(REPLAY_AGES) do s.older[k] = { n = 0, mb = 0 } end
  s.older.oldVersion = { n = 0, mb = 0 }
  isDamaged('') -- loads the list of unplayable files
  for _, f in ipairs(replayFiles()) do
    s.n, s.mb = s.n + 1, s.mb + f.size / 1e6
    if f.oldVersion and not f.busy then s.older.oldVersion.n, s.older.oldVersion.mb = s.older.oldVersion.n + 1, s.older.oldVersion.mb + f.size / 1e6 end
    for k, days in pairs(REPLAY_AGES) do
      if f.age > days * 86400 and not f.busy then s.older[k].n, s.older[k].mb = s.older[k].n + 1, s.older[k].mb + f.size / 1e6 end
    end
  end
  s.mb = floor(s.mb + 0.5)
  for _, o in pairs(s.older) do o.mb = floor(o.mb + 0.5) end
  return s
end
M.deleteOldReplays = function(age)
  local days = REPLAY_AGES[age]
  if not days and age ~= 'oldVersion' then return 0 end
  local n, mb = 0, 0
  isDamaged('')
  for _, f in ipairs(replayFiles()) do
    if not f.busy and ((days and f.age > days * 86400) or (age == 'oldVersion' and f.oldVersion)) then
      FS:removeFile(f.path)
      n, mb = n + 1, mb + f.size / 1e6
    end
  end
  log('I', logTag, string.format('deleted %d replay files (%s, %.0f MB), as asked', n, days and ('older than ' .. days .. ' days') or 'from an older game version', mb))
  guihooks.message(string.format('Deleted %d replay file%s (%.0f MB).', n, n == 1 and '' or 's', mb), 5, 'coDriverAnalysis')
  if result then refreshReplayFlags() sendData() end
  sendState()
  return n
end
-- Every setting the panel shows, from all the extensions (each keeps its own file).
M.requestSettings = function()
  local s = { analysis = options, storage = M.replayStorage() }
  if coDriverCoach and coDriverCoach.getSettings then
    local ok, c = pcall(coDriverCoach.getSettings)
    if ok then s.coach = c end
  end
  if coDriverLaps and coDriverLaps.getOptions then
    local ok, o = pcall(coDriverLaps.getOptions)
    local ok2, r = pcall(coDriverLaps.getRoutes)
    local ok3, c = pcall(function() return coDriverLaps.getCourses and coDriverLaps.getCourses() or {} end)
    if ok then s.laps = { discovery = o.discovery, ghost = o.ghost, level = o.level, routes = ok2 and r or {}, courses = ok3 and c or {} } end
    if s.laps and coDriverCoach and coDriverCoach.recceInfo then -- recce notes per route, and whether one is being recorded
      local ids = {}
      for _, x in ipairs(s.laps.routes) do ids[#ids + 1] = x.id end
      for _, x in ipairs(s.laps.courses) do if x.enabled then ids[#ids + 1] = x.id end end
      local okR, info = pcall(coDriverCoach.recceInfo, o.level, ids)
      s.laps.recce = okR and info or {}
      local okS, st = pcall(coDriverCoach.recceState)
      s.laps.recceState = okS and st or nil
      s.laps.guided = coDriverLaps.getGuided and coDriverLaps.getGuided() or nil
    end
  end
  guihooks.trigger('CoDriverSettings', s)
end
M.openSettings = function()
  openPanel()
  guihooks.trigger('CoDriverOpenSettings', {})
  M.requestSettings()
end
M.hasSession = function() return rec ~= nil and #rec.samples > 40 end
M.isRecording = function() return rec ~= nil end
M.isOpen = function() return panelOpen end
M.loadLast = function() local ok = loadLast() if ok then openPanel() end return ok end
M.loadSession = loadSession
M.listSessions = listSessions
M.requestSessions = function() guihooks.trigger('CoDriverAnalysisSessions', listSessions()) end
M.replayCorner = replayCorner
-- the timeline: seek within the loaded file (keeping pause), or start playing from just before t
M.replayAt = function(t)
  local idx = replay and replay.ready and partIndexAt(t)
  if idx and idx == replay.part then seekSession(t) else playFrom(replay and t or t - 2) end
end
M.replayStep = replayStep
M.getReplayState = function() return replay and { t = replay.t, corner = replay.corner, ready = replay.ready, paused = replay.paused, msg = replay.msg, part = replay.part } end
M.setReplayPartSecs = function(secs) secs = tonumber(secs) PART_SECS = (secs and secs > 0) and max(20, secs) or nil end -- tests only; 0 or nil turns rotation off
M.setReplaySpeed = setReplaySpeed
M.setReplayPaused = setReplayPaused
M.exitReplay = exitReplay
M.getResult = function() return result end
M._ownerRuns = ownerRuns -- for the offline tests
M.getRecording = function() return rec end
M.endSession = endSession

return M
