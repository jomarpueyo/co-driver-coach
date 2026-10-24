-- Co-Driver Coach: race engineer on the radio.
-- * Push-to-talk questions (hotkey or the analysis panel's mic) turned into text and answered by
--   Claude Haiku through the local bridge (tools/engineer.py), or by rules when it has no API key.
-- * Watches the car mid-drive (brakes, tyres, engine, fuel, damage) and calls out problems.
-- * Knows the weather and time of day.
-- * Makes light, temporary car adjustments when the driver asks (brake bias, brake strength, force
--   feedback, and the car's electronics: drive mode, ESC, traction control, ABS, launch control,
--   AWD centre lock): the bridge returns them with the answer, the vehicle (coDriverRec) applies them.
-- The bridge and the game talk through JSON files in settings/coDriverCoach/engineer/.
local M = {}
local logTag = 'coDriverEngineer'
local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local DIR = 'settings/coDriverCoach/engineer/'
local SETTINGS = 'settings/coDriverCoach/engineer_settings.json'
local defaults = { alerts = true, speak = true, speakDrive = false, lapCalls = false, ownVoice = true } -- speak: analysis answers; speakDrive: mid-drive answers and alerts; lapCalls: lap times spoken at the line; ownVoice: a line whose every word is in your voicepack is said in your voice

local cfg = {}
local clock, reqN = 0, 0
local pending = {}          -- id -> { cb, t }
local bridge = { online = false }
local bridgeCheckT, statusT, lastStatusT, gameBeatN = 0, 0, -10, 0
local status = nil          -- latest raw car status
local talk = nil            -- push-to-talk in progress
local busy = false          -- waiting for an answer
local history = {}          -- recent questions and answers for the UI
local alertState = {}       -- per alert: armed flag and last time
-- the drive's last 50 events (corners with their speed, crashes, resets, laps, alerts), sent with each
-- mid-drive question so "how was that corner?" has an answer; evCursor = what was read from the coach
local events = {}
local evCursor = { corners = 0, crashes = 0, resets = 0 }

local function loadSettings()
  local s = FS:fileExists(SETTINGS) and jsonReadFile(SETTINGS) or {}
  for k, v in pairs(defaults) do cfg[k] = s[k] == nil and v or s[k] end
end

local function saveSettings() jsonWriteFile(SETTINGS, cfg, true) end

-- units -------------------------------------------------------------------------

local function imperial() return settings.getValue('uiUnitLength') == 'imperial' end
local function tempUnit() return settings.getValue('uiUnitTemperature') == 'f' and 'F' or 'C' end
local function temp(c) return tempUnit() == 'F' and floor(c * 9 / 5 + 32 + 0.5) or floor(c + 0.5) end
local function speedText(ms) return imperial() and floor(ms * 2.23694 + 0.5) .. ' mph' or floor(ms * 3.6 + 0.5) .. ' km/h' end

-- bridge ------------------------------------------------------------------------

local function sendState()
  guihooks.trigger('CoDriverEngineerState', {
    online = bridge.online, llm = bridge.llm, stt = bridge.stt, tts = bridge.tts, sttEngine = bridge.sttEngine, ttsEngine = bridge.ttsEngine,
    listening = talk ~= nil, busy = busy, history = history, speak = cfg.speak, speakDrive = cfg.speakDrive, alerts = cfg.alerts, lapCalls = cfg.lapCalls,
    ownVoice = cfg.ownVoice,
  })
end

local function checkBridge()
  local exists = FS:fileExists(DIR .. 'bridge.json')
  local b = exists and jsonReadFile(DIR .. 'bridge.json')
  local was = bridge.online
  if exists and type(b) ~= 'table' then return end -- caught mid-update: keep the last state
  if type(b) == 'table' and b.t then
    bridge = { online = os.time() - b.t < 5, llm = b.llm, stt = b.stt, tts = b.tts, model = b.model, sttEngine = b.sttEngine, ttsEngine = b.ttsEngine }
  else
    bridge = { online = false }
  end
  if was ~= bridge.online then sendState() end
end

local function send(kind, payload, cb)
  if not FS:directoryExists(DIR) then FS:directoryCreate(DIR, true) end
  reqN = reqN + 1
  local id = string.format('%d_%05d', os.time(), reqN)
  payload = payload or {}
  payload.type, payload.id = kind, id
  local tmp = DIR .. 'tmp_' .. id .. '.json'
  jsonWriteFile(tmp, payload, false)
  FS:renameFile(tmp, DIR .. 'req_' .. id .. '.json') -- the bridge never sees a half-written file
  if cb then pending[id] = { cb = cb, t = clock, kind = kind } end
end

local function pollResponses()
  for id, p in pairs(pending) do
    local fn = DIR .. 'res_' .. id .. '.json'
    if FS:fileExists(fn) then
      local res = jsonReadFile(fn) or {}
      FS:removeFile(fn)
      pending[id] = nil
      local ok, err = pcall(p.cb, res)
      if not ok then log('E', logTag, 'callback failed: ' .. tostring(err)) end
    elseif clock - p.t > (p.kind == 'ask' and 40 or 10) then
      pending[id] = nil
      pcall(p.cb, { error = 'The engineer did not answer in time.' })
    end
  end
end

-- Say something in the engineer's voice when the bridge runs; always show it too.
-- a line in your own voice (the voicepack's clips) when every word of it is recorded
local function ownVoice(text)
  return cfg.ownVoice and coDriverCoach and coDriverCoach.sayPhrase and coDriverCoach.sayPhrase(text) or false
end

local function radio(text, critical)
  guihooks.message('Engineer: ' .. text, critical and 8 or 6, 'coDriverEngineer')
  if cfg.speakDrive and not ownVoice(text) and bridge.online and bridge.tts then send('say', { text = text }) end
end

-- car condition -----------------------------------------------------------------

local WHEEL_NAMES = { FL = 'front left', FR = 'front right', RL = 'rear left', RR = 'rear right' }
local function wheelName(n) return WHEEL_NAMES[n] or tostring(n) end

local ENGINE_PROBLEMS = {
  coolantOverheating = 'coolant overheating', oilOverheating = 'oil overheating', radiatorLeak = 'radiator leak',
  oilpanLeak = 'oil pan leak', oilRadiatorLeak = 'oil cooler leak', headGasketDamaged = 'head gasket damaged',
  engineReducedTorque = 'engine down on power', starvedOfOil = 'engine starved of oil', oilLevelCritical = 'oil level critical',
  turbochargerHot = 'turbo running hot', turbochargerDamaged = 'turbo damaged', superchargerDamaged = 'supercharger damaged',
  engineDisabled = 'engine dead', engineLockedUp = 'engine seized', exhaustBroken = 'exhaust broken',
  mildOverrevDamage = 'over-rev damage', catastrophicOverrevDamage = 'serious over-rev damage',
  pistonRingsDamaged = 'piston rings damaged', rodBearingsDamaged = 'rod bearings damaged',
  inductionSystemDamaged = 'intake damaged', engineHydrolocked = 'engine hydrolocked', impactDamage = 'engine impact damage',
}

-- tyre temperatures arrive in Kelvin; brake and engine temperatures in Celsius
local function tyreC(k) return k and k - 273.15 or nil end
-- thermal efficiency is also low on cold brakes: only count it as fade once they are hot
local FADE_MIN_TEMP = 300
local function fadeEff(w) return (w.brakeEff and (w.brakeT or 0) > FADE_MIN_TEMP) and w.brakeEff or 1 end

local function psi(pa)
  if not pa or pa <= 0 then return nil end
  local g = (pa - 101325) / 6894.76
  return g > -5 and g or nil
end

-- A readable summary of the raw status, in the game's units, for answers and alerts.
local function carSummary()
  if not status then return nil end
  local s = status
  local brakesF, brakesR, nF, nR, worstEff, tyreSum, tyreN, flats, pressures, broken = 0, 0, 0, 0, 1, 0, 0, {}, {}, {}
  for _, w in ipairs(s.wheels or {}) do
    local front = tostring(w.name):sub(1, 1) == 'F'
    if w.brakeT then
      if front then brakesF, nF = brakesF + w.brakeT, nF + 1 else brakesR, nR = brakesR + w.brakeT, nR + 1 end
    end
    worstEff = min(worstEff, fadeEff(w))
    if w.tyreT then tyreSum, tyreN = tyreSum + tyreC(w.tyreT), tyreN + 1 end
    if w.flat then table.insert(flats, wheelName(w.name)) end
    if w.broken then table.insert(broken, wheelName(w.name)) end
    local p = psi(w.pressure)
    if p then table.insert(pressures, p) end
  end
  local out = { tempUnit = tempUnit(), pressureUnit = imperial() and 'psi' or 'bar' }
  if nF + nR > 0 then
    local avg = (brakesF + brakesR) / (nF + nR)
    out.brakes = { front = temp(nF > 0 and brakesF / nF or 0), rear = temp(nR > 0 and brakesR / nR or 0), worstFade = floor((1 - worstEff) * 100 + 0.5),
      cold = avg < 80 or nil }
  end
  if tyreN > 0 or #flats > 0 then
    out.tyres = { avg = temp(tyreN > 0 and tyreSum / tyreN or 0), flat = flats, broken = broken }
    if #pressures > 0 then
      local lo, hi = math.huge, -math.huge
      for _, p in ipairs(pressures) do lo, hi = min(lo, p), max(hi, p) end
      local f = imperial() and 1 or 0.0689476
      local dec = imperial() and 0 or 1
      local r = function(x) local m = 10 ^ dec return floor(x * f * m + 0.5) / m end
      out.tyres.pressure = r(lo) == r(hi) and tostring(r(lo)) or (r(lo) .. ' to ' .. r(hi))
    end
  end
  local problems = {}
  for _, k in ipairs(s.engineFlags or {}) do if ENGINE_PROBLEMS[k] then table.insert(problems, ENGINE_PROBLEMS[k]) end end
  out.engine = { water = temp(s.water or 0), oil = temp(s.oil or 0), running = s.running == 1 or s.running == true, problems = problems }
  if s.fuel then out.fuel = floor(s.fuel * 100 + 0.5) end
  local parts = {}
  for k, v in pairs(s.body or {}) do table.insert(parts, { k, v }) end
  table.sort(parts, function(a, b) return a[2] > b[2] end)
  local names = {}
  for i = 1, min(3, #parts) do names[i] = parts[i][1]:gsub('_', ' ') end
  local d = s.damage or 0
  out.damage = { level = d < 1000 and 'none' or (d < 8000 and 'light' or (d < 30000 and 'moderate' or 'heavy')), parts = names }
  return out
end

local function weatherSummary()
  local ok, st = pcall(core_environment.getState)
  if not ok or type(st) ~= 'table' then return nil end
  local t = (st.time or 0) % 1 -- 0 = noon in BeamNG
  local hours = (t * 24 + 12) % 24
  local cc = st.cloudCover or 0
  return {
    time = string.format('%d:%02d', floor(hours), floor((hours % 1) * 60)),
    temp = temp(st.temperatureC or 15), tempUnit = tempUnit(),
    sky = cc < 0.3 and 'clear' or (cc < 1 and 'some cloud' or 'overcast'),
    rain = (st.numOfDrops or 0) > 0 or nil, fog = (st.fogDensity or 0) > 5 or nil,
    wind = (st.windSpeed or 0) > 3 and floor(st.windSpeed + 0.5) or nil,
    night = hours < 6 or hours > 20 or nil,
  }
end

local function pushEvent(text)
  events[#events + 1] = { t = clock, text = text }
  if #events > 50 then table.remove(events, 1) end
end

-- Proactive calls: each alert fires once, then re-arms after the condition clears (or after a cooldown).
local function alert(key, active, text, critical, cooldown)
  local a = alertState[key] or { armed = true, t = -1e9 }
  alertState[key] = a
  if active and a.armed and clock - a.t > (cooldown or 60) then
    a.armed, a.t = false, clock
    pushEvent('alert: ' .. text)
    radio(text, critical)
  elseif not active then
    a.armed = true
  end
end

local function checkAlerts()
  if not cfg.alerts or not status then return end
  local s = status
  local worstEff, molten = 1, false
  for _, w in ipairs(s.wheels or {}) do
    alert('flat_' .. tostring(w.name), w.flat, 'Puncture, ' .. wheelName(w.name) .. '. Ease off and bring it home.', true, 1e9)
    alert('broken_' .. tostring(w.name), w.broken, wheelName(w.name) .. ' wheel is broken.', true, 1e9)
    worstEff = min(worstEff, fadeEff(w))
    molten = molten or w.molten
    if w.tyreT then alert('tyrehot', tyreC(w.tyreT) > 125, 'Tyres are overheating. Smooth inputs for a bit.', false, 120) end
  end
  alert('fade', worstEff < 0.85 and worstEff >= 0.7, 'Brakes are fading. Brake earlier and give them a cool-down lap.', false, 90)
  alert('fadebad', worstEff < 0.7, 'Brakes badly faded, they will not stop you like before. Back off now.', true, 60)
  alert('molten', molten, 'Brake has failed from heat.', true, 1e9)
  alert('water', (s.water or 0) > 118, 'Engine is overheating, water at ' .. temp(s.water or 0) .. ' degrees. Short shift and back off.', false, 90)
  alert('oil', (s.oil or 0) > 135, 'Oil temperature is high, ' .. temp(s.oil or 0) .. ' degrees.', false, 90)
  local flags = {}
  for _, k in ipairs(s.engineFlags or {}) do flags[k] = true end
  for k, text in pairs(ENGINE_PROBLEMS) do
    if k ~= 'coolantOverheating' and k ~= 'oilOverheating' and k ~= 'turbochargerHot' then
      alert('eng_' .. k, flags[k], 'Engine: ' .. text .. '.', true, 1e9)
    end
  end
  alert('turbo', flags.turbochargerHot, 'Turbo is running hot. Give it a breather.', false, 120)
  if s.fuel and s.fuel > 0 then
    alert('fuel10', s.fuel < 0.1 and s.fuel >= 0.04, 'Fuel is low, about ' .. floor(s.fuel * 100 + 0.5) .. ' percent.', false, 1e9)
    alert('fuel4', s.fuel < 0.04, 'Fuel critical.', true, 1e9)
  end
end

local adjustStatus -- set in the car adjustments section

local function onStatus(id, s)
  local veh = getPlayerVehicle(0)
  if not veh or veh:getId() ~= id or type(s) ~= 'table' then return end
  status, lastStatusT = s, clock
  if adjustStatus then pcall(adjustStatus, veh, s) end
  local ok, err = pcall(checkAlerts)
  if not ok then log('E', logTag, 'alerts failed: ' .. tostring(err)) end
end

-- context for answers ---------------------------------------------------------------

-- corners the coach finished since the last look, and new crashes and resets (once a second)
local function pollEvents()
  local d = coDriverCoach and coDriverCoach.getDriveEvents and coDriverCoach.getDriveEvents(evCursor.corners)
  if not d then return end
  if d.n < evCursor.corners or d.crashes < evCursor.crashes then -- a new drive
    evCursor.corners, evCursor.crashes, evCursor.resets = 0, 0, 0
    return
  end
  for i = max(1, #d.corners - 49), #d.corners do
    local c = d.corners[i]
    local s = 'corner ' .. tostring(c.text or '?') .. ' at ' .. speedText(c.minSpeed or 0)
    if c.vSafe and c.minSpeed and c.minSpeed > c.vSafe * 1.1 then s = s .. ', over the called ' .. speedText(c.vSafe)
    elseif c.vSafe and c.minSpeed and c.minSpeed < c.vSafe * 0.8 then s = s .. ', well under the called ' .. speedText(c.vSafe) end
    if c.incident then s = s .. ', with an incident' end
    pushEvent(s)
  end
  if d.crashes > evCursor.crashes then pushEvent('crash') end
  if d.resets > evCursor.resets then pushEvent('car reset') end
  evCursor.corners, evCursor.crashes, evCursor.resets = d.n, d.crashes, d.resets
end

-- the last 12 events of the past 10 minutes, newest last: "35 s ago: corner 3 Left at 54 mph"
local function recentEvents()
  local out = {}
  for i = max(1, #events - 11), #events do
    local e = events[i]
    local ago = floor(clock - e.t)
    if ago <= 600 then out[#out + 1] = ago .. ' s ago: ' .. e.text end
  end
  return #out > 0 and out or nil
end

local function driveContext()
  local veh = getPlayerVehicle(0)
  local ctx = { car = carSummary(), weather = weatherSummary() }
  if veh then
    ctx.speed = speedText(vec3(veh:getVelocity()):length())
    ctx.vehicle = veh:getJBeamFilename()
  end
  if coDriverCoach and coDriverCoach.getDebugState then
    local ok, d = pcall(coDriverCoach.getDebugState)
    if ok and d and d.drive then
      ctx.drive = { minutes = floor((d.drive.time or 0) / 6) / 10, km = floor((d.drive.dist or 0) / 100) / 10,
        corners = d.drive.corners, crashes = d.drive.crashes, offRoadSeconds = floor(d.drive.offRoadTime or 0) }
    end
  end
  if coDriverCoach and coDriverCoach.getGrip then
    local lat, brk = coDriverCoach.getGrip()
    ctx.grip = { corneringG = floor((lat or 0) * 100) / 100, brakingG = floor((brk or 0) * 100) / 100 }
  end
  ctx.adjust = status and status.adjust
  ctx.recent = recentEvents()
  if coDriverLaps and coDriverLaps.radioState then
    local ok, l = pcall(coDriverLaps.radioState)
    if ok then ctx.laps = l end
  end
  return ctx
end

-- car adjustments asked for by voice --------------------------------------------------
-- The bridge returns actions with a mid-drive answer: { kind, value } with kind
--   bias (points of braking moved to the front, against stock), brake (percent of stock torque),
--   ffb (percent of the binding's force feedback), awdLock (percent minimum centre lock),
--   launchRPM, esc / tc / abs / launch (true or false), driveMode (one of the car's modes),
--   value 'stock' for any of them, or kind revert.
-- The vehicle (coDriverRec) clamps them to the limits and to what the car has, applies them on the
-- next straight with the brake off, keeps them through resets and reports back through onAdjust.
-- Here they are kept for this session and this car (the vehicle's carId: model, config file and a
-- digest of its parts and tuning): a reload of the same car gets them back, a different car or the
-- end of the session clears them. Nothing is saved.
local ADJ_SCALE = { bias = 100, brake = 100, ffb = 100, awdLock = 100, launchRPM = 1 }
local ADJ_TOGGLES = { esc = true, tc = true, abs = true, launch = true }
local adjStore = nil  -- { vid, key = carId, targets } for the player's car, this session only
local adjPushT, adjCheckT, adjWasRec, adjGoneT = -1e9, nil, false, -1e9

local function vehCmd(veh, cmd)
  veh:queueLuaCommand('if not coDriverRec then extensions.load("coDriverRec") end if coDriverRec and coDriverRec.adjust then ' .. cmd .. ' end')
end

local function applyActions(actions)
  local veh = getPlayerVehicle(0)
  if not veh or type(actions) ~= 'table' then return nil end
  local change, cmds = {}, {}
  for _, a in ipairs(actions) do
    local kind, val = type(a) == 'table' and a.kind, type(a) == 'table' and a.value
    local num = tonumber(val)
    if kind == 'revert' then
      table.insert(cmds, 'coDriverRec.revert("driver")')
    elseif ADJ_SCALE[kind] and val == 'stock' then
      change[kind] = 'stock'
    elseif ADJ_SCALE[kind] and num and num == num and abs(num) < 1e5 then
      change[kind] = num / ADJ_SCALE[kind]
    elseif ADJ_TOGGLES[kind] and (type(val) == 'boolean' or val == 'stock') then
      change[kind] = val
    elseif kind == 'driveMode' and type(val) == 'string' and #val <= 40 and val:match('^[%w_ %-]+$') then
      change[kind] = val
    end
  end
  if next(change) then table.insert(cmds, 'coDriverRec.adjust(' .. serialize(change) .. ', "driver")') end
  if #cmds == 0 then return nil end
  local cmd = table.concat(cmds, ' ')
  vehCmd(veh, cmd)
  return cmd
end

local function modeName(info, key)
  for _, m in ipairs(info.driveModes or {}) do if m.key == key then return m.name end end
  return key
end

local function adjustText(info)
  local parts, t = {}, info.targets or {}
  if (info.biasShift or 0) ~= 0 then table.insert(parts, string.format('brake bias %s%% front (%+g)', tostring(info.frontPct or '?'), info.biasShift)) end
  if info.brakePct and info.brakePct ~= 100 then table.insert(parts, 'brakes ' .. info.brakePct .. '%') end
  if info.ffbPct and info.ffbPct ~= 100 then table.insert(parts, 'force feedback ' .. info.ffbPct .. '%') end
  if t.driveMode then table.insert(parts, modeName(info, t.driveMode) .. ' mode') end
  local onOff = function(b) return b and 'on' or 'off' end
  if t.esc ~= nil then table.insert(parts, 'ESC ' .. onOff(t.esc)) end
  if t.tc ~= nil then table.insert(parts, 'traction control ' .. onOff(t.tc)) end
  if t.abs ~= nil then table.insert(parts, 'ABS ' .. onOff(t.abs)) end
  if t.launch ~= nil or t.launchRPM then
    table.insert(parts, 'launch control ' .. (t.launch == false and 'off' or (t.launchRPM and floor(t.launchRPM) .. ' rpm' or 'on')))
  end
  if t.awdLock then table.insert(parts, 'centre lock ' .. floor(t.awdLock * 100 + 0.5) .. '%') end
  return #parts > 0 and table.concat(parts, ', ') or 'everything stock'
end

-- keep the set for this car (or forget it once it is all stock)
local function keepAdjust(veh, info)
  if type(info.targets) == 'table' and next(info.targets) then
    adjStore = { vid = veh:getId(), key = info.carId, targets = info.targets }
  else
    adjStore = nil
  end
end

-- put the kept set on a reloaded copy of the same car
local function restoreAdjust(veh)
  adjPushT = clock
  vehCmd(veh, 'coDriverRec.adjust(' .. serialize(adjStore.targets) .. ', "restore", true)')
end

-- session over or car changed: back to stock (queued: the car may still be moving)
local function clearAdjust(reason)
  local veh = getPlayerVehicle(0)
  if adjStore and veh and veh:getId() == adjStore.vid then
    vehCmd(veh, 'coDriverRec.revert(' .. serialize(reason) .. ')')
  end
  adjStore = nil
end

-- The vehicle's report: event 'queued' (waiting for a straight), 'applied', 'kept' (after a
-- reset), 'restored' (after a reload) or 'reverted'.
local function onAdjust(id, info, event, reason)
  if type(info) ~= 'table' or reason == 'switch' then return end
  local veh = getPlayerVehicle(0)
  if not veh or veh:getId() ~= id then return end
  if status then status.adjust = info end
  keepAdjust(veh, info)
  if event == 'applied' then
    guihooks.message('Engineer: set, ' .. adjustText(info) .. '.', 5, 'coDriverEngineerAdj')
  elseif event == 'queued' then
    guihooks.message('Engineer: ' .. adjustText(info) .. ' on the next straight.', 4, 'coDriverEngineerAdj')
  elseif (event == 'kept' or event == 'restored') and adjStore then
    guihooks.message('Engineer: still set after the ' .. (event == 'kept' and 'reset' or 'reload') .. ', ' .. adjustText(info) .. '.', 5, 'coDriverEngineerAdj')
  elseif event == 'reverted' and reason == 'ffb settings' then
    guihooks.message('Engineer: force feedback back on your wheel setting (its settings changed).', 5, 'coDriverEngineerAdj')
  elseif event == 'reverted' and reason == 'drive mode' then
    guihooks.message('Engineer: your drive mode choice replaces my electronics changes.', 5, 'coDriverEngineerAdj')
  elseif event == 'reverted' then
    guihooks.message('Engineer: adjustments back to stock' .. (reason == 'session' and ' (session over)' or '') .. '.', 5, 'coDriverEngineerAdj')
  end
end

-- From each status: a fresh vehicle VM with no set is a reload. The same car (carId) gets the set
-- back; another car in the same slot clears it.
adjustStatus = function(veh, s)
  if type(s.adjust) ~= 'table' then return end
  if adjStore and adjStore.vid == veh:getId() and not next(s.adjust.targets or {}) then
    if s.adjust.carId ~= adjStore.key then
      adjStore = nil
    elseif clock - adjPushT > 5 then
      restoreAdjust(veh)
    end
  elseif next(s.adjust.targets or {}) then
    keepAdjust(veh, s.adjust)
  end
end

-- Once a second: the end of the coach's session (Review, coach off, level end) clears the set;
-- a pending restore after a reload goes out.
local function adjustTick()
  local rec = coDriverAnalysis and coDriverAnalysis.isRecording and coDriverAnalysis.isRecording() or false
  -- (a reload makes the car vanish for a moment, which also ends the recording: that isn't the end of the session)
  if adjWasRec and not rec and clock - adjGoneT > 3 then clearAdjust('session') end
  adjWasRec = rec
  if adjCheckT and clock >= adjCheckT then -- after a spawn: ask the car what it has (works with the coach off too)
    adjCheckT = nil
    adjPushT = -1e9
    local veh = getPlayerVehicle(0)
    if veh and adjStore and veh:getId() == adjStore.vid then
      veh:queueLuaCommand('extensions.load("coDriverRec") if coDriverRec and coDriverRec.sendStatus then coDriverRec.sendStatus() end')
    end
  end
end

-- a car spawned, reloaded or replaced in the player's slot: check it once it has loaded
local function onVehicleSpawned(vid)
  if adjStore and vid == adjStore.vid then adjCheckT, adjGoneT = clock + 1.5, clock end
end

local function lapClock(t)
  if not t then return nil end
  local m = floor(t / 60)
  return string.format('%d:%05.2f', m, t - m * 60)
end

-- The laps of the reviewed drive: times, gaps, sectors and where each lost most, by turn (T1..
-- are the same place on every lap).
local function lapsContext(r, lapKey)
  local L = r.laps
  if type(L) ~= 'table' or type(L.list) ~= 'table' or #L.list == 0 then return nil end
  local list, byKey = {}, {}
  for _, l in ipairs(L.list) do byKey[l.key] = l end
  -- "T7 entry to T8 entry 0.99 s": the sharpest stretches first, 3 per lap (6 for the studied one)
  local function places(xs, k, withLap)
    local out = {}
    for i = 1, math.min(k, type(xs) == 'table' and #xs or 0) do
      local x, by = xs[i], withLap and byKey[xs[i].by]
      out[#out + 1] = string.format('%s%s %.2f s', x.where or '?', by and string.format(' (lap %d)', by.n) or '', x.gain or 0)
    end
    return #out > 0 and table.concat(out, ', ') or nil
  end
  for _, l in ipairs(L.list) do
    local lost = {}
    for _, x in ipairs(l.top or {}) do lost[#lost + 1] = string.format('T%d +%.2f s', x.turn, x.loss) end
    local k = l.key == lapKey and 6 or 3
    list[#list + 1] = { lap = l.n, time = lapClock(l.time), valid = l.valid, notCountedBecause = l.reason,
      gapToBest = l.delta, sectors = l.sectors, lostMostVsBestPasses = table.concat(lost, ', '),
      whereLostVsBestLap = l.key ~= L.ref and places(l.stretches, k) or nil,
      quickerThanBestLapAt = l.key ~= L.ref and places(l.ahead, 2) or nil,
      otherLapsQuickerAt = l.key == L.ref and places(l.stretches, k, true) or nil }
  end
  local best = L.ref and byKey[L.ref]
  local turns = {}
  for _, tn in ipairs(L.turns or {}) do
    turns[#turns + 1] = { turn = tn.id, dir = tn.dir, bestPass = tn.best, bestOnLap = tn.bestLap and byKey[tn.bestLap] and byKey[tn.bestLap].n, timesByLap = tn.times }
  end
  local sel = lapKey and byKey[lapKey]
  return { note = 'Turn numbers T1.. are the same place on every lap (corner ids count through the whole drive; call a corner by its "where"). Sectors are thirds of the lap. timesByLap is in lap order, -1 = not reached. lapTimeStdDevS is the standard deviation of the valid lap times. whereLostVsBestLap: the stretches of road where that lap lost the most time per metre to the best lap (10 m cells; "T6 exit to 40 m before T7 0.42 s"); otherLapsQuickerAt: for the best lap, where another lap was quicker. Use these places when asked where time was lost.',
    laps = list, bestLap = best and best.n, theoreticalBest = lapClock(L.theoretical10 or L.theoretical), lapTimeStdDevS = L.spread,
    lengthKm = L.length and floor(L.length / 10) / 100, turns = turns, studying = sel and ('lap ' .. sel.n) or 'whole drive' }
end

-- The analysis, trimmed to what an engineer needs (a few KB).
local function reviewContext(selected, lapKey)
  local r = coDriverAnalysis and coDriverAnalysis.getResult()
  if not r or not r.corners then return { note = 'No analysis available.' } end
  local mul = r.unit == 'mph' and 2.23694 or 3.6
  local sp = function(v) return v and floor(v * mul + 0.5) or nil end
  local byId, ranked = {}, {}
  for _, c in ipairs(r.corners) do byId[c.id] = c end
  -- the costliest corners, the selected one and those of the lap being studied (a long drive has
  -- 80+ corners, and sending them all made every review question about 9k tokens)
  local keep, kept = {}, 0
  for _, id in ipairs(r.order or {}) do
    if kept < 20 then keep[id], kept = true, kept + 1 end
  end
  if selected then keep[selected] = true end
  for _, c in ipairs(r.corners) do if lapKey and c.lap == lapKey then keep[c.id] = true end end
  for _, id in ipairs(r.order or {}) do
    local c = keep[id] and byId[id]
    if c then
      table.insert(ranked, {
        id = c.id, dir = c.unneeded and 'brake zone (no corner needed)' or c.dir, radiusM = c.radius,
        brakeZoneGradePct = c.gradePct,
        loss = c.loss, note = c.note, minSpeed = sp(c.minSpeed), idealMin = sp(c.idealMin),
        exitSpeed = sp(c.exitSpeed), idealExit = sp(c.idealExit), brakedEarlierM = c.brakeDiff,
        brakeRiseS = c.brakeRise, brakePeakPct = c.brakePeak and floor(c.brakePeak * 100) or nil,
        coastS = c.coast, throttleLateS = c.throttleLateS, wideOfApexM = c.apexGap,
        steerCorrectionsPerS = c.sawRate, trailBraked = c.trail, incident = c.incident, gripUsePct = c.gripUse and floor(c.gripUse * 100) or nil,
        slowerThanBestPassS = c.vsBest, balance = c.balance,
        where = (function()
          local l = c.lap and r.laps and r.laps.list and r.laps.list[c.lap]
          if not l then return nil end
          return c.turn and string.format('lap %d, turn %d', l.n, c.turn) or string.format('lap %d, corner %d (not one of the turns)', l.n, c.id)
        end)(),
      })
    end
  end
  local tips = {}
  for i, t in ipairs(r.tips or {}) do tips[i] = { text = t.text, corners = t.corners } end
  return {
    session = r.date, level = r.level, unit = r.unit, driveSeconds = r.tDrive, betterLineSeconds = r.tIdeal,
    gap = r.gap, gapWithoutIncidents = r.gapClean, incidents = r.incidents, top3 = r.top3, model = r.limits and string.format('better line uses %s g cornering and %s g braking: the limit of the car model (robust corner and braking peaks, aero, brake capacity) at a %d%% margin',
      tostring(r.limits.lat), tostring(r.limits.brk), floor(((r.model and r.model.margin) or 0.95) * 100 + 0.5)) or nil,
    power = r.model and r.model.powerMeasuredKW and string.format('%d kW measured at the wheels on full-throttle pulls (around %d km/h; listed engine power %s kW, so drivetrain loss and drag show as the difference)',
      r.model.powerMeasuredKW, r.model.powerMeasuredKmh or 0, tostring(r.model.powerKW or '?')) or nil,
    balanceNote = 'a corner\'s balance: "pushed wide" = understeer (less turn than the steering asked for, near the grip limit), "rear stepped out" = oversteer (the car pointing further into the turn than it travels)',
    selectedCorner = selected, tips = tips, corners = ranked, cornersNote = string.format('corners: the %d costliest of %d, the selected one and the studied lap\'s, by time lost', min(20, #r.corners), #r.corners),
    weather = weatherSummary(), laps = lapsContext(r, lapKey),
  }
end

-- questions -------------------------------------------------------------------------

local function remember(q, a, source)
  table.insert(history, { q = q, a = a, source = source })
  while #history > 6 do table.remove(history, 1) end
end

local function reviewOpen() return coDriverAnalysis and coDriverAnalysis.isOpen and coDriverAnalysis.isOpen() end

local function ask(question, mode, selected, lapKey)
  mode = mode or (reviewOpen() and 'review' or 'drive')
  question = tostring(question or '')
  if not bridge.online then
    -- no bridge: still answer car questions from the data we have
    if mode == 'drive' then
      local c = carSummary()
      local a = c and string.format('Brakes front %s, rear %s. Engine water %s. Fuel %s%%.', c.brakes and c.brakes.front or '-', c.brakes and c.brakes.rear or '-', c.engine.water, c.fuel or '-') or 'No car data yet.'
      remember(question ~= '' and question or 'Status', a .. ' (start tools/engineer.bat for voice and Haiku)', 'game')
      guihooks.message('Engineer: ' .. a, 8, 'coDriverEngineer')
    else
      remember(question, 'The engineer bridge is not running. Double-click tools/engineer.bat, then ask again.', 'game')
    end
    sendState()
    return
  end
  busy = true
  sendState()
  local data = mode == 'review' and reviewContext(selected, lapKey) or driveContext()
  local speak = (mode == 'review') and cfg.speak or (mode == 'drive' and cfg.speakDrive)
  -- with your voicepack's phrases, the bridge leaves a fully covered answer for the game to say in your voice
  local words = speak and cfg.ownVoice and coDriverCoach and coDriverCoach.voiceWords and coDriverCoach.voiceWords() or nil
  send('ask', { question = question, mode = mode, data = data, speak = speak, voiceWords = words }, function(res)
    busy = false
    local a = res.text or res.error or 'No answer.'
    remember(question ~= '' and question or (mode == 'review' and 'Debrief' or 'Status'), a, res.source or 'error')
    if mode == 'drive' and res.actions then applyActions(res.actions) end
    if res.ownVoice and not ownVoice(a) and bridge.tts then send('say', { text = a }) end -- the clips can't play now: Kokoro after all
    if mode == 'drive' then guihooks.message('Engineer: ' .. a, 10, 'coDriverEngineer') end
    sendState()
  end)
end

local function talkDown(mode)
  if talk then return end
  checkBridge()
  if not bridge.online then
    guihooks.message('Engineer: start tools/engineer.bat to talk to me (voice needs the bridge).', 6, 'coDriverEngineer')
    if (mode or (reviewOpen() and 'review')) ~= 'review' then ask('', 'drive') end -- still give a status
    return
  end
  if not bridge.stt then
    guihooks.message('Engineer: no microphone found by Windows speech recognition.', 6, 'coDriverEngineer')
    return
  end
  talk = { mode = mode or (reviewOpen() and 'review' or 'drive'), t = clock }
  send('listen', { mode = talk.mode }, function(res)
    if res.error then guihooks.message('Engineer: microphone problem: ' .. tostring(res.error), 6, 'coDriverEngineer') end
  end)
  guihooks.message('Engineer: listening...', 2, 'coDriverEngineer')
  sendState()
end

local function talkUp(selected, lapKey)
  if not talk then return end
  local t = talk
  talk = nil
  busy = true
  sendState()
  send('stop', {}, function(res)
    busy = false
    local text = res.text or ''
    if text == '' then
      guihooks.message('Engineer: didn\'t catch that. Hold the button while you talk.', 4, 'coDriverEngineer')
      sendState()
      return
    end
    guihooks.trigger('CoDriverEngineerHeard', { text = text })
    if t.mode == 'drive' then guihooks.message('You: ' .. text, 4, 'coDriverEngineerQ') end
    ask(text, t.mode, selected, lapKey)
  end)
end

-- main loop --------------------------------------------------------------------------

local function onUpdate(dtReal)
  clock = clock + dtReal
  bridgeCheckT = bridgeCheckT - dtReal
  if bridgeCheckT <= 0 then
    bridgeCheckT = 2
    checkBridge()
    -- the game's heartbeat for the bridge, every 20 s (it polls slowly once this file is a minute old:
    -- game closed). A write costs about 1 ms on this thread, so not more often.
    gameBeatN = gameBeatN + 1
    if gameBeatN % 10 == 1 and FS:directoryExists(DIR) then pcall(writeFile, DIR .. 'game.json', tostring(os.time())) end
  end
  if next(pending) then pollResponses() end
  -- car status once a second while the coach is on (and not watching a replay)
  statusT = statusT - dtReal
  if statusT <= 0 then
    statusT = 1
    adjustTick()
    local okE, errE = pcall(pollEvents)
    if not okE then log('E', logTag, 'events failed: ' .. tostring(errE)) end
    local veh = getPlayerVehicle(0)
    local on = coDriverCoach and coDriverCoach.isEnabled and coDriverCoach.isEnabled()
    if veh and on and core_replay.getState() ~= 'playback' then
      if clock - lastStatusT > 5 then
        veh:queueLuaCommand('extensions.load("coDriverRec") if coDriverRec and coDriverRec.sendStatus then coDriverRec.sendStatus() end')
      else
        veh:queueLuaCommand('if coDriverRec and coDriverRec.sendStatus then coDriverRec.sendStatus() end')
      end
    end
  end
end

local function onVehicleSwitched(oldId, newId)
  if not newId or newId < 0 then
    -- the car is gone for now (a reload fires (-1, -1), then the same car comes back): wait and see,
    -- onVehicleSpawned and the next status compare the car's id
    adjGoneT = clock
  elseif oldId ~= newId then
    -- a car change: the car we left goes back to stock (the player isn't in it, so no ramp is needed)
    local old = oldId and oldId >= 0 and getObjectByID(oldId)
    if old then old:queueLuaCommand('if coDriverRec and coDriverRec.revert then coDriverRec.revert("switch", true) end') end
    if adjStore and newId == adjStore.vid then
      adjCheckT = clock + 1.5 -- the same car back after a reload
    else
      adjStore = nil
    end
  end
  status, alertState, lastStatusT = nil, {}, -10
  if oldId ~= newId and newId and newId >= 0 and not (adjStore and newId == adjStore.vid) then events = {} end
end

local function onVehicleResetted()
  alertState = {} -- a reset repairs the car: everything re-arms (the vehicle keeps its adjustments itself)
end

M.onExtensionLoaded = function() loadSettings() checkBridge() end
M.onUpdate = onUpdate
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleResetted = onVehicleResetted
M.onStatus = onStatus
M.onAdjust = onAdjust
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleReplaced = onVehicleSpawned
M.onClientEndMission = function() adjStore = nil end
-- console: the adjustments kept for this car and session (nil = none)
M.getKeptAdjustments = function() return adjStore end
M.applyActions = applyActions
-- console: revert the car's adjustments now
M.revertAdjustments = function() applyActions({ { kind = 'revert' } }) end
M.talkDown = talkDown
M.talkUp = talkUp
M.ask = ask
M.requestState = sendState
-- A lap time the way an engineer says it: 60.52 -> 'one oh oh point five', 83.6 -> 'one twenty-three point six'.
local DIGITS = { [0] = 'oh', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine' }
local function spokenTime(t)
  local t10 = floor(t * 10 + 0.5) -- in tenths, so 59.96 rounds up to one minute
  local m = floor(t10 / 600)
  local whole, tenth = floor((t10 - m * 600) / 10), t10 % 10
  local secs = whole < 10 and ('oh ' .. DIGITS[whole]) or tostring(whole)
  if m == 0 then return string.format('%d point %s', whole, DIGITS[tenth] == 'oh' and 'zero' or DIGITS[tenth]) end
  return string.format('%s %s point %s', m < 10 and DIGITS[m] or tostring(m), secs, DIGITS[tenth] == 'oh' and 'zero' or DIGITS[tenth])
end
local function spokenGap(d)
  local a = abs(d)
  if a < 0.05 then return 'same as your best' end
  local amount = a < 1 and string.format('%s tenth%s', DIGITS[floor(a * 10 + 0.5)] or tostring(floor(a * 10 + 0.5)), floor(a * 10 + 0.5) == 1 and '' or 's')
    or string.format('%.1f', a)
  return d < 0 and (amount .. ' quicker') or (amount .. ' off your best')
end

-- From coDriverLaps at the line: the lap time spoken over the radio (lapCalls, needs the bridge).
M.onLap = function(info)
  if type(info) == 'table' and not info.partial and info.time then
    pushEvent(string.format('lap %d %s%s', info.n or 0, lapClock(info.time), not info.valid and ', not counted' or
      (info.best and ', new best' or (info.deltaBest and string.format(', %+.2f s to the best', info.deltaBest) or ''))))
  end
  if not cfg.lapCalls or not bridge.online or not bridge.tts or type(info) ~= 'table' or info.partial then return end
  local text
  if not info.valid then
    text = string.format('Lap %d, %s, not counted.', info.n, spokenTime(info.time))
  elseif info.best and info.deltaBest then
    text = string.format('Lap %d, %s. New best, %s.', info.n, spokenTime(info.time), spokenGap(info.deltaBest))
  elseif info.deltaBest then
    text = string.format('Lap %d, %s, %s.', info.n, spokenTime(info.time), spokenGap(info.deltaBest))
  else
    text = string.format('Lap %d, %s.', info.n, spokenTime(info.time))
  end
  send('say', { text = text })
end
M._spokenTime = spokenTime
M._spokenGap = spokenGap

M.setOption = function(key, value)
  if defaults[key] == nil then return end
  cfg[key] = value and true or false
  saveSettings()
  sendState()
end
M.getCar = carSummary
M.getWeather = weatherSummary
M.getDriveContext = driveContext
M.getEvents = function() return events end
M.getReviewContext = reviewContext
M.getStatus = function() return status end
M.getBridge = function() return bridge end

return M
