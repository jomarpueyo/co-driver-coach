-- Co-Driver Coach telemetry recorder (vehicle VM). Samples the car about 60 times a second
-- (every graphics frame, capped) with frame-time timestamps and sends the samples to the game
-- engine (coDriverAnalysis.onChunk) in batches every half second. At start it also sends what
-- the analysis needs to know about the car (coDriverAnalysis.onCarInfo).
local M = {}

local STEP, SEND = 0.016, 0.5  -- a sample at most every 16 ms: every frame at 60 fps, about 60 Hz above
local active = false
local t, acc, sendAcc = 0, 0, 0
local buf, n = {}, 0
local fmt = string.format
local surfClass = nil -- ground material id -> surface class (see below)
local weight = 1      -- the car's weight (N), for the load factor

-- Surface classes sent with each sample: 0 airborne, 1 tarmac, 2 wet tarmac, 3 gravel or dirt,
-- 4 grass, mud or sand, 5 snow or ice.
local CLASS = {
  ASPHALT = 1, COBBLESTONE = 1, RUMBLE_STRIP = 1, ROCK = 1, METAL = 1, WOOD = 1, PLASTIC = 1, GLASS = 1,
  ASPHALT_WET = 2, WATER = 2,
  GRAVEL = 3, DIRT = 3, DIRT_DUSTY = 3, SANDY_ROAD = 3,
  GRASS = 4, MUD = 4, SAND = 4, FOLIAGE = 4, FOLIAGE_THIN = 4,
  SNOW = 5, ICE = 5, SLIPPERY = 5,
}
local function buildSurfaceClasses()
  surfClass = {}
  local ok, mats = pcall(particles.getMaterialsParticlesTable)
  for id, m in pairs(ok and mats or {}) do surfClass[id] = CLASS[m.name] or 1 end
end

-- Mean applied brake torque as a share of each wheel's capacity: the closest thing to brake pressure.
local function brakeRatio()
  local sum, cnt = 0, 0
  for _, w in pairs(wheels.wheelRotators or {}) do
    local cap = w.brakeTorque or 0
    if cap > 0 then
      sum = sum + math.min((w.brakingTorque or 0) / cap, 1)
      cnt = cnt + 1
    end
  end
  return cnt > 0 and sum / cnt or 0
end

-- Total tyre load as a share of the car's weight (aero downforce raises it with speed), and the
-- surface carrying most of that load.
local function loadAndSurface()
  local total, by = 0, {}
  for _, w in pairs(wheels.wheelRotators or {}) do
    local f = w.downForceRaw or 0
    local mat = w.contactMaterialID1 or -1
    if mat == 4 then mat = w.contactMaterialID2 or -1 end -- 4 is the tyre's own rubber
    if f > 0 and mat >= 0 then
      total = total + f
      local c = surfClass[mat] or 1
      by[c] = (by[c] or 0) + f
    end
  end
  local best, bestF = 0, 0
  for c, f in pairs(by) do if f > bestF then best, bestF = c, f end end
  return total / weight, best
end

local function sample()
  local e = electrics.values
  local p, v, d = obj:getPosition(), obj:getVelocity(), obj:getDirectionVector()
  local abs = e.absActive
  abs = (abs == true or (type(abs) == 'number' and abs > 0)) and 1 or 0
  local load, surf = loadAndSurface()
  n = n + 1
  buf[n] = fmt('{%.3f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.0f,%d,%.3f,%.2f,%.3f,%d}',
    t, p.x, p.y, p.z, v.x, v.y, v.z, d.x, d.y,
    e.throttle_input or e.throttle or 0, e.brake_input or e.brake or 0, e.steering_input or 0,
    tonumber(e.gearIndex) or 0, e.rpm or 0, abs, brakeRatio(), e.wheelspeed or 0, load, surf)
end

-- What the analysis needs to know about the car: mass, power, brakes, driven wheels, ABS.
local function carInfo()
  local info = { mass = 0, powerKW = 0, brakeN = 0, driven = '', abs = false, wheels = 0 }
  local ok, bs = pcall(function() return obj:calcBeamStats() end)
  info.mass = ok and bs and bs.total_weight or 0
  local okE, eng = pcall(function() return powertrain.getDevicesByCategory('engine')[1] end)
  if okE and eng and eng.maxPower then info.powerKW = eng.maxPower * 0.7457 end -- the game's maxPower is in hp
  local front, rear = false, false
  for _, w in pairs(wheels.wheelRotators or {}) do
    info.wheels = info.wheels + 1
    if (w.radius or 0) > 0.05 then info.brakeN = info.brakeN + (w.brakeTorque or 0) / w.radius end
    if w.hasABS then info.abs = true end
    if w.isPropulsed then
      local name = tostring(w.name or '')
      if name:sub(1, 1) == 'F' then front = true else rear = true end
    end
  end
  info.driven = (front and rear) and 'AWD' or (front and 'FWD' or (rear and 'RWD' or ''))
  return info
end

local function flush()
  if n == 0 then return end
  obj:queueGameEngineLua('if coDriverAnalysis then coDriverAnalysis.onChunk(' .. obj:getId() .. ',{' .. table.concat(buf, ',', 1, n) .. '}) end')
  buf, n = {}, 0
end

-- driver adjustments, for the race engineer -----------------------------------------
-- What the driver can change mid-drive by asking the engineer: brake bias, overall brake strength,
-- steering force feedback, and the car's own electronics where it has them (drive mode, ESC,
-- traction control, ABS, two-step launch, AWD centre lock). Nothing is saved: brake torque is set
-- from each wheel's initialBrakeTorque, force feedback from the binding's strength, electronics
-- through the controllers' live parameters. A change waits until the wheel is near straight and
-- the brake is off; force feedback ramps over about a second. ABS, ESC and traction control read
-- brakeTorque live, so they follow.
-- Adjustments stay through a vehicle reset: the game's reset puts brake torque and the drive mode
-- back, then they are applied again on the next frame. They go when the game engine says so
-- (session ended, car changed). The state lives in the shared global, so reloading this
-- extension keeps it.
local LIMITS = { bias = { -0.10, 0.10 }, brake = { 0.8, 1.1 }, ffb = { 0.6, 1.3 }, awdLock = { 0, 0.6 }, launchRPM = { 1500, 9000 } }
local STOCK = { bias = 0, brake = 1, ffb = 1 }
local EXT = { driveMode = true, esc = true, tc = true, abs = true, launch = true, launchRPM = true, awdLock = true }
local TOGGLES = { esc = 'esc', tc = 'tc', abs = 'abs', launch = 'launch' } -- toggle -> capability
local CALM_STEER, CALM_BRAKE, CALM_SECS, FFB_RAMP = 0.08, 0.02, 0.4, 1.0

local function adjState()
  if not rawget(_G, 'coDriverRecShared') then rawset(_G, 'coDriverRecShared', { damage = {} }) end -- (rawset: no new-global warning)
  local a = coDriverRecShared.adj
  if not a then
    a = { bias = 0, brake = 1, ffb = 1, ffbNow = 1, calm = 0, ext = {} }
    coDriverRecShared.adj = a
  end
  a.ext = a.ext or {}
  return a
end

local function clampNum(x, lo, hi)
  x = tonumber(x)
  if not x or x ~= x then return nil end
  return math.max(lo, math.min(hi, x))
end

local function ctrl(name)
  local ok, c = pcall(controller.getController, name)
  return ok and c or nil
end

-- Braked wheels by axle (names start with F at the front), the stock front share of the brake
-- torque, and whether the car has brakes on both axles (needed to move the bias).
local function brakeSplit()
  local front, rear, sumF, sumR = {}, {}, 0, 0
  for _, wd in pairs(wheels.wheelRotators or {}) do
    local t0 = wd.initialBrakeTorque
    if t0 and t0 > 0 and wd.brakeTorque then
      if tostring(wd.name or ''):sub(1, 1) == 'F' then
        front[#front + 1], sumF = wd, sumF + t0
      else
        rear[#rear + 1], sumR = wd, sumR + t0
      end
    end
  end
  local total = sumF + sumR
  return front, rear, total > 0 and sumF / total or nil, sumF > 0 and sumR > 0
end

-- The car's drive modes in their order, from its jbeam (one vehicle VM is one car, so once).
local modeList
local function driveModeList()
  if modeList then return modeList end
  modeList = {}
  local dm = ctrl('driveModes')
  if not dm then return modeList end
  for _, c in pairs(v.data and v.data.controller or {}) do
    if c.fileName == 'driveModes' then
      for k, keys in pairs(c) do
        if type(k) == 'string' and k:sub(1, 12) == 'enabledModes' and type(keys) == 'table' then
          for _, key in pairs(keys) do
            local d = dm.getDriveModeData(key)
            if d then modeList[#modeList + 1] = { key = key, name = d.name or key, order = d.order or 0 } end
          end
        end
      end
    end
  end
  table.sort(modeList, function(x, y) return x.order < y.order end)
  return modeList
end

-- What this car lets the driver change.
local function caps()
  local _, _, f0, canBias = brakeSplit()
  local abs = false
  for _, wd in pairs(wheels.wheelRotators or {}) do if wd.hasABS then abs = true end end
  local launchMax
  if ctrl('twoStepLaunch') then
    local ok, eng = pcall(function() return powertrain.getDevicesByCategory('engine')[1] end)
    local maxRPM = ok and eng and tonumber(eng.maxRPM) or 7000
    launchMax = math.floor(math.max(LIMITS.launchRPM[1] + 500, math.min(LIMITS.launchRPM[2], maxRPM * 0.9)))
  end
  return { canBias = canBias, stockFront = f0, abs = abs, esc = ctrl('yawControl') ~= nil, tc = ctrl('tractionControl') ~= nil,
    launch = launchMax ~= nil, launchMax = launchMax, awdLock = ctrl('electronicSplitShaftLock') ~= nil, modes = driveModeList() }
end

-- A requested change, clamped to the limits and to what the car has. All absolute:
-- bias = front share shift (0.02 = 2 points), brake = torque coefficient, ffb = coefficient of
-- the binding's strength, awdLock = minimum centre lock 0-0.6, launchRPM, esc/tc/abs/launch =
-- booleans, driveMode = one of the car's mode keys (or its name). 'stock' clears one.
local function clampAdjust(t, c)
  c = c or caps()
  local out = {}
  for k, lim in pairs(LIMITS) do
    if t[k] == 'stock' then
      out[k] = STOCK[k] or 'stock'
    elseif t[k] ~= nil then
      out[k] = clampNum(t[k], lim[1], k == 'launchRPM' and (c.launchMax or lim[2]) or lim[2])
    end
  end
  for k in pairs(TOGGLES) do
    if t[k] == 'stock' or type(t[k]) == 'boolean' then out[k] = t[k] end
  end
  if t.driveMode == 'stock' then
    out.driveMode = 'stock'
  elseif type(t.driveMode) == 'string' then
    local want = t.driveMode:lower()
    for _, m in ipairs(c.modes or {}) do
      if m.key:lower() == want or tostring(m.name):lower() == want then out.driveMode = m.key end
    end
  end
  if not c.canBias then out.bias = nil end
  for k, cap in pairs(TOGGLES) do if not c[cap] then out[k] = nil end end
  if not c.launch then out.launchRPM = nil end
  if not c.awdLock then out.awdLock = nil end
  if #(c.modes or {}) == 0 then out.driveMode = nil end
  return out
end

-- Front and rear torque coefficients that move the front share by `bias` and keep the total.
local function biasCoefs(f0, bias)
  if not f0 or f0 <= 0 or f0 >= 1 or bias == 0 then return 1, 1 end
  local f = math.max(0.05, math.min(0.95, f0 + bias))
  return f / f0, (1 - f) / (1 - f0)
end

local function applyBrakes(a)
  local front, rear, f0, canBias = brakeSplit()
  local cF, cR = biasCoefs(canBias and f0 or nil, a.bias)
  for _, wd in ipairs(front) do wd.brakeTorque = wd.initialBrakeTorque * a.brake * cF end
  for _, wd in ipairs(rear) do wd.brakeTorque = wd.initialBrakeTorque * a.brake * cR end
end

-- Force feedback at k times the binding's strength (both the at-speed and the parking-speed value,
-- the way the game's own input tests scale it).
local function writeFFB(a, k)
  if not a.ffbBase then a.ffbBase, a.ffbBaseLow = hydros.wheelFFBForceCoef, hydros.wheelFFBForceCoefLowSpeed end
  hydros.wheelFFBForceCoef = a.ffbBase * k
  hydros.wheelFFBForceCoefLowSpeed = a.ffbBaseLow * k
  a.ffbNow = k
  if k == 1 then -- back on the binding's own value: nothing left to look after
    a.ffbBase, a.ffbBaseLow, a.ffbWritten = nil, nil, nil
  else
    a.ffbWritten = hydros.wheelFFBForceCoef
  end
end

-- The game read the binding again (its force feedback settings changed): its value wins.
local function ffbTakenBack(a)
  if a.ffbWritten and math.abs((hydros.wheelFFBForceCoef or 0) - a.ffbWritten) > 1e-6 then
    a.ffbBase, a.ffbBaseLow, a.ffbWritten, a.ffbT = nil, nil, nil, nil
    a.ffb, a.ffbNow = 1, 1
    if a.want then a.want.ffb = nil end
    return true
  end
end

local function currentMode()
  local dm = ctrl('driveModes')
  return dm and dm.getCurrentDriveModeKey() or nil
end

-- Electronics back on the car's own settings: the drive mode's (or the controllers' defaults on a
-- car without drive modes), and the game's ABS setting if ABS was changed.
local function restoreExt(mode, abs)
  local dm = ctrl('driveModes')
  local key = mode or (dm and dm.getCurrentDriveModeKey())
  if dm and key then
    dm.setDriveMode(key)
  else
    for _, n in ipairs({ 'yawControl', 'tractionControl' }) do
      local c = ctrl(n)
      if c and c.setParameters then c.setParameters({ isEnabled = 'default' }) end
    end
    local lock = ctrl('electronicSplitShaftLock')
    if lock and lock.setParameters then lock.setParameters({ minimumLock = 'default' }) end
    local two = ctrl('twoStepLaunch')
    if two and two.setParameters then two.setParameters({ isEnabled = false }) end
  end
  if abs and wheels.resetABSBehavior then wheels.resetABSBehavior() end
end

-- Our electronics on top of whatever the car runs now.
local function applyExt(a)
  local e = a.ext
  local dm = ctrl('driveModes')
  if e.driveMode and dm and dm.getCurrentDriveModeKey() ~= e.driveMode then dm.setDriveMode(e.driveMode) end
  local function setP(name, p)
    local c = ctrl(name)
    if c and c.setParameters then c.setParameters(p) end
  end
  if e.esc ~= nil then setP('yawControl', { isEnabled = e.esc }) end
  if e.tc ~= nil then setP('tractionControl', { isEnabled = e.tc }) end
  if e.awdLock then setP('electronicSplitShaftLock', { minimumLock = e.awdLock }) end
  if e.launch ~= nil or e.launchRPM then setP('twoStepLaunch', { isEnabled = e.launch, launchRPM = e.launchRPM }) end
  if e.abs ~= nil and wheels.setABSBehavior then
    local d = settings and settings.getValue and settings.getValue('absBehavior') or 'realistic'
    wheels.setABSBehavior(e.abs and (d == 'off' and 'realistic' or d) or 'off')
  end
  a.modeSeen = currentMode()
end

-- Everything that differs from stock, waiting changes included (what the game engine keeps).
local function targets(a)
  local t, w = {}, a.want or {}
  for k, s in pairs(STOCK) do
    local val = w[k]
    if val == nil then val = a[k] end
    if val ~= s then t[k] = val end
  end
  for k in pairs(EXT) do
    local val = w[k]
    if val == nil then val = a.ext[k] elseif val == 'stock' then val = nil end
    if val ~= nil then t[k] = val end
  end
  return t
end

-- This car: model, config file, and a digest of its parts and tuning values, sorted so it is the
-- same after a reload (the game's own serialized config comes out in a different order).
local function carId()
  local c = v.config or {}
  local items = {}
  local function walk(node)
    if type(node) ~= 'table' then return end
    if node.path and node.chosenPartName then items[#items + 1] = tostring(node.path) .. '=' .. tostring(node.chosenPartName) end
    for _, ch in pairs(node.children or {}) do walk(ch) end
  end
  walk(c.partsTree)
  for k, x in pairs(c.vars or {}) do items[#items + 1] = tostring(k) .. '=' .. tostring(x) end
  table.sort(items)
  local str, h = table.concat(items, ';'), 5381
  for i = 1, #str do h = (h * 33 + str:byte(i)) % 2147483647 end -- fits 32-bit integers (fengari) and doubles (LuaJIT)
  return tostring(c.model or v.vehicleDirectory) .. '|' .. tostring(c.partConfigFilename or '') .. '|' .. string.format('%08x', h)
end

-- What the car's electronics are doing now (ours or the drive mode's): ESC and traction control from
-- the controllers, centre lock and launch control from our change or the mode's settings.
local function electronicsNow(a, c)
  local now, e = {}, a.ext
  for k, n in pairs({ esc = 'yawControl', tc = 'tractionControl' }) do
    local ctl = c[k] and ctrl(n)
    local ok, cfg = pcall(function() return ctl and ctl.getConfig and ctl.getConfig() end)
    if ok and type(cfg) == 'table' and type(cfg.isEnabled) == 'boolean' then now[k] = cfg.isEnabled end
  end
  local dm = ctrl('driveModes')
  local mode = dm and dm.getCurrentDriveModeKey() and dm.getDriveModeData(dm.getCurrentDriveModeKey())
  local set = type(mode) == 'table' and mode.settings or {}
  local lock = set.electronicSplitShaftLock and set.electronicSplitShaftLock.minimumLock
  if c.awdLock then now.awdLock = e.awdLock or (type(lock) == 'number' and lock or nil) end
  local two = set.twoStepLaunch or {}
  if c.launch then
    if e.launch ~= nil then now.launch = e.launch elseif type(two.isEnabled) == 'boolean' then now.launch = two.isEnabled end
    now.launchRPM = e.launchRPM or tonumber(two.launchRPM)
  end
  if e.abs ~= nil then now.abs = e.abs end
  return now
end

-- What is set, for the engineer. biasShift/brakePct/ffbPct are the targets (still waiting for a
-- straight when `waiting`); `applied` is what the car has right now; `targets` is everything that
-- differs from stock in the units adjust() takes.
local function adjustInfo()
  local a = adjState()
  local c = caps()
  local w = a.want or {}
  local pct = function(x) return math.floor(x * 1000 + 0.5) / 10 end
  local bias = w.bias or a.bias
  local f0 = c.stockFront
  local ffbId = hydros.getFFBID and hydros.getFFBID() or -1
  local info = {
    biasShift = pct(bias), brakePct = pct(w.brake or a.brake), ffbPct = pct(w.ffb or a.ffb),
    stockFrontPct = f0 and pct(f0) or nil, frontPct = f0 and pct(c.canBias and f0 + bias or f0) or nil,
    canBias = c.canBias, ffbDevice = ffbId >= 0, waiting = a.want ~= nil or nil, ramping = a.ffbT ~= nil or nil,
    applied = { biasShift = pct(a.bias), brakePct = pct(a.brake), ffbPct = pct(a.ffbNow) },
    targets = targets(a), driveMode = currentMode(), stockMode = a.stockMode or nil, now = electronicsNow(a, c), carId = carId(),
    has = { esc = c.esc, tc = c.tc, abs = c.abs, launch = c.launch, awdLock = c.awdLock }, launchMaxRPM = c.launchMax,
  }
  if #c.modes > 0 then
    info.driveModes = {}
    for i, m in ipairs(c.modes) do info.driveModes[i] = { key = m.key, name = m.name } end
  end
  return info
end

local function notifyAdjust(event, reason)
  obj:queueGameEngineLua('if coDriverEngineer and coDriverEngineer.onAdjust then coDriverEngineer.onAdjust(' .. obj:getId() .. ','
    .. serialize(adjustInfo()) .. ',' .. serialize(event) .. ',' .. serialize(reason or '') .. ') end')
end

local function applyWanted(a, event)
  local w = a.want
  a.want = nil
  a.bias, a.brake = w.bias or a.bias, w.brake or a.brake
  applyBrakes(a)
  if w.ffb then
    a.ffb = w.ffb
    if w.ffb ~= a.ffbNow then a.ffbFrom, a.ffbT = a.ffbNow, 0 end
  end
  local touched, removed, absRemoved = false, false, false
  for k in pairs(EXT) do
    if w[k] == 'stock' then
      touched = true
      if a.ext[k] ~= nil then removed, absRemoved = true, absRemoved or k == 'abs' end
      a.ext[k] = nil
    elseif w[k] ~= nil then
      touched, a.ext[k] = true, w[k]
    end
  end
  if touched then
    if removed then restoreExt(a.ext.driveMode or a.stockMode, absRemoved) end
    applyExt(a)
    if next(a.ext) == nil then a.stockMode, a.modeSeen = nil, nil end
  end
  local reverting = a.reverting
  a.reverting = nil
  if reverting then notifyAdjust('reverted', reverting) else notifyAdjust(event or 'applied') end
end

-- Queue a change (any of the keys clampAdjust takes); it applies on the next calm moment, or at
-- once with `now` (restoring the set onto a reloaded car).
local function adjust(t, reason, now)
  if type(t) ~= 'table' then return end
  local a = adjState()
  local c = caps()
  local x = clampAdjust(t, c)
  if next(x) == nil then return end
  for k in pairs(EXT) do
    if x[k] ~= nil and x[k] ~= 'stock' and a.stockMode == nil then a.stockMode = currentMode() or false end
  end
  a.want = a.want or {}
  for k, val in pairs(x) do a.want[k] = val end
  a.calm, a.reverting = 0, nil
  if now then applyWanted(a, 'restored') else notifyAdjust('queued', reason) end
end

-- Everything back to stock. now = right away (car switched away, session ended while parked),
-- otherwise it waits for a straight like any other change.
local function revert(reason, now)
  local a = adjState()
  ffbTakenBack(a)
  local changed = next(targets(a)) ~= nil or a.ffbNow ~= 1
  if not now then
    if changed then
      local t = { bias = 0, brake = 1, ffb = 1 }
      for k in pairs(EXT) do if a.ext[k] ~= nil or (a.want and a.want[k] ~= nil) then t[k] = 'stock' end end
      adjust(t, reason)
      a.reverting = reason or 'driver' -- reported as reverted once it applies
    end
    return
  end
  local hadExt, hadAbs = next(a.ext) ~= nil, a.ext.abs ~= nil
  a.want, a.ffbT, a.calm, a.bias, a.brake, a.ffb, a.reapply = nil, nil, 0, 0, 1, 1, nil
  applyBrakes(a)
  if a.ffbBase then writeFFB(a, 1) end
  a.ffbNow = 1
  if hadExt then
    a.ext = {}
    restoreExt(a.stockMode or nil, hadAbs)
  end
  a.stockMode, a.modeSeen = nil, nil
  if changed then notifyAdjust('reverted', reason) end
end

local function updateAdjust(a, dt)
  if a.reapply then -- after a vehicle reset: the game put its own values back, ours go on top again
    a.reapply = nil
    applyBrakes(a)
    if a.ffbBase and a.ffbNow ~= 1 then writeFFB(a, a.ffbNow) end
    if next(a.ext) then applyExt(a) end
    notifyAdjust('kept', 'reset')
  end
  if ffbTakenBack(a) then notifyAdjust('reverted', 'ffb settings') end
  if a.modeSeen and next(a.ext) then
    local cur = currentMode()
    if cur and cur ~= a.modeSeen then -- the driver picked a drive mode: theirs wins over our electronics
      local abs = a.ext.abs
      a.ext = { abs = abs }
      if a.want then for k in pairs(EXT) do if k ~= 'abs' then a.want[k] = nil end end end
      a.stockMode, a.modeSeen = cur, cur
      if abs == nil then a.stockMode, a.modeSeen = nil, nil end
      notifyAdjust('reverted', 'drive mode')
    end
  end
  if a.want then
    local e = electrics.values
    local calm = math.abs(e.steering_input or 0) < CALM_STEER and (e.brake_input or e.brake or 0) < CALM_BRAKE
    a.calm = calm and a.calm + dt or 0
    if a.calm >= CALM_SECS then applyWanted(a) end
  end
  if a.ffbT then
    a.ffbT = a.ffbT + dt
    local x = math.min(a.ffbT / FFB_RAMP, 1)
    if x >= 1 then
      a.ffbT = nil
      writeFFB(a, a.ffb)
    else
      writeFFB(a, a.ffbFrom + (a.ffb - a.ffbFrom) * x * x * (3 - 2 * x)) -- smoothstep: no step at either end
    end
  end
end

local function updateGFX(dt)
  local A = coDriverRecShared and coDriverRecShared.adj
  if A and dt > 0 and (A.want or A.ffbT or A.ffbWritten or A.reapply or (A.ext and next(A.ext))) then updateAdjust(A, dt) end
  if not active or dt <= 0 then return end
  t = t + dt
  acc = acc + dt
  if acc >= STEP then
    acc = math.min(acc - STEP, STEP) -- no catching up after a long frame
    sample()
  end
  sendAcc = sendAcc + dt
  if sendAcc >= SEND then
    sendAcc = 0
    flush()
  end
end

local function start()
  active, t, acc, sendAcc, buf, n = true, 0, 0, 0, {}, 0
  if not surfClass then buildSurfaceClasses() end
  local info = carInfo()
  weight = info.mass > 0 and info.mass * 9.81 or 1e4
  obj:queueGameEngineLua('if coDriverAnalysis and coDriverAnalysis.onCarInfo then coDriverAnalysis.onCarInfo(' .. obj:getId() .. ',' .. serialize(info) .. ') end')
end

local function stop()
  if active then flush() end
  active = false
end

-- car condition, for the race engineer ------------------------------------------

-- latest damageTracker data (engine flags, body parts, ...). damageTracker has no way to remove a
-- callback, so it is registered once per vehicle VM and shared through a global: reloading this
-- extension no longer stacks up callbacks.
if not rawget(_G, 'coDriverRecShared') then rawset(_G, 'coDriverRecShared', { damage = {} }) end -- (rawset: no new-global warning)
if not coDriverRecShared.hooked and damageTracker and damageTracker.registerDamageUpdateCallback then
  coDriverRecShared.hooked = pcall(damageTracker.registerDamageUpdateCallback, function(data) coDriverRecShared.damage = data or {} end)
end

local function wheelStatus(wd)
  local w = {
    name = wd.name, brakeT = wd.brakeSurfaceTemperature, brakeCore = wd.brakeCoreTemperature,
    brakeEff = wd.brakeThermalEfficiency, glaze = wd.padGlazingFactor,
    molten = wd.isBrakeMolten or nil, flat = wd.isTireDeflated or nil, broken = wd.isBroken or nil,
  }
  if wd.wheelID then
    pcall(function()
      w.tyreT = obj:getWheelAvgTemperature(wd.wheelID)
      w.tyreCore = obj:getWheelCoreTemperature(wd.wheelID)
    end)
  end
  local groups = v.data and v.data.pressureGroups
  if wd.pressureGroup and groups and groups[wd.pressureGroup] then
    pcall(function() w.pressure = obj:getGroupPressure(groups[wd.pressureGroup]) end)
  end
  return w
end

-- One snapshot of the car's condition, sent to coDriverEngineer.onStatus.
local function sendStatus()
  local e = electrics.values
  local s = {
    fuel = e.fuel, water = e.watertemp, oil = e.oiltemp, running = e.engineRunning,
    checkengine = e.checkengine, damage = beamstate and beamstate.damage or 0, wheels = {},
    engineFlags = {}, wheelFlags = {}, body = {},
  }
  for _, wd in pairs(wheels.wheelRotators or {}) do
    local ok, w = pcall(wheelStatus, wd)
    if ok then table.insert(s.wheels, w) end
  end
  local damage = coDriverRecShared.damage or {}
  for k, val in pairs(damage.engine or {}) do
    if val == true or (type(val) == 'number' and val > 0) then table.insert(s.engineFlags, k) end
  end
  for k, val in pairs(damage.wheels or {}) do
    if val == true or (type(val) == 'number' and val > 0) then table.insert(s.wheelFlags, k) end
  end
  for k, val in pairs(damage.body or {}) do
    if type(val) == 'number' and val > 0.05 then s.body[k] = math.floor(val * 100) / 100 end
  end
  local ok, adj = pcall(adjustInfo)
  if ok then s.adjust = adj end
  obj:queueGameEngineLua('if coDriverEngineer then coDriverEngineer.onStatus(' .. obj:getId() .. ',' .. serialize(s) .. ') end')
end

M.updateGFX = updateGFX
M.start = start
M.stop = stop
M.isActive = function() return active end
M.sendStatus = sendStatus
M.adjust = adjust
M.revert = revert
M.getAdjust = adjustInfo
M.clampAdjust = clampAdjust
M.biasCoefs = biasCoefs
M.getCaps = caps
-- A vehicle reset puts brakeTorque and the drive mode back (wheels.reset, controller.resetLastStage):
-- the adjustments are applied again on the next frame. hydros.reset then brings the force feedback
-- limit up from zero, and the game doesn't touch the strength, so force feedback simply stays.
M.onReset = function()
  local a = coDriverRecShared and coDriverRecShared.adj
  if a and (a.want or next(targets(a)) or a.ffbNow ~= 1) then a.reapply, a.calm = true, 0 end
end

return M
