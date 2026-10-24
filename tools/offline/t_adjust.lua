-- Race-engineer car adjustments, offline: coDriverRec.lua (vehicle VM) runs as A and
-- coDriverEngineer.lua (game engine, path in SRC) is loaded here. The two talk through captured
-- queueLuaCommand / queueGameEngineLua strings, as in the game. Covers the clamping, the queue until
-- the wheel is straight and the brake is off, the brake torque split, the force feedback ramp, the
-- car's electronics (drive mode, ESC, traction control, ABS, launch control, centre lock), keeping
-- everything through a vehicle reset and a reload of the same car, and clearing it (voice, session
-- end, car switch or change, the game re-reading the binding, the driver picking a drive mode).
-- Run from an empty folder
-- (it writes settings/coDriverCoach/engineer/ there):
--   SRC=<repo>/co_driver_coach/lua/ge/extensions/coDriverEngineer.lua node <repo>/tools/offline/run.js \
--     <repo>/co_driver_coach/lua/vehicle/extensions/coDriverRec.lua <repo>/tools/offline/t_adjust.lua
local fails, checks = 0, 0
local function check(name, cond, detail)
  checks = checks + 1
  if not cond then fails = fails + 1 end
  print((cond and 'ok   ' or 'FAIL ') .. name .. (detail and ('  (' .. tostring(detail) .. ')') or ''))
end
local function near(a, b, eps) return type(a) == 'number' and math.abs(a - b) < (eps or 1e-6) end

function serialize(v)
  if type(v) == 'string' then return string.format('%q', v) end
  if type(v) ~= 'table' then return tostring(v) end
  local o = {}
  for k, x in pairs(v) do o[#o + 1] = '[' .. serialize(k) .. ']=' .. serialize(x) end
  return '{' .. table.concat(o, ',') .. '}'
end

-- vehicle VM ---------------------------------------------------------------------------
local function wheel(name, t) return { name = name, brakeTorque = t, initialBrakeTorque = t } end
local W = { [0] = wheel('FL', 2000), wheel('FR', 2000), wheel('RL', 1000), wheel('RR', 1000) }
wheels = { wheelRotators = W }
hydros = { wheelFFBForceCoef = 250, wheelFFBForceCoefLowSpeed = 25, getFFBID = function() return 0 end }
electrics = { values = { steering_input = 0, brake_input = 0, fuel = 0.5, watertemp = 90, oiltemp = 95 } }
local GEQ, VQ, OLDQ, MSG = {}, {}, {}, {}
obj = { getId = function() return 7 end, queueGameEngineLua = function(_, s) GEQ[#GEQ + 1] = s end }
extensions = { load = function() end }
coDriverRec = A
for _, w in pairs(W) do w.hasABS = true end
-- the Vivace's electronics: drive modes set ESC, TC, centre lock and launch; the controllers take
-- setParameters like the game's (isEnabled / minimumLock 'default' = the car's own)
local MODES = { comfort = { name = 'Comfort', order = 10, on = true, lock = 0 }, sport = { name = 'Sport', order = 20, on = true, lock = 0.25 },
  arsenic = { name = 'Arsenic', order = 30, on = true, lock = 0.4 }, off = { name = 'ESC & TC Off', order = 50, on = false, lock = 0.25 } }
local CT = { mode = 'arsenic', esc = true, tc = true, lock = 0.4, launch = true, rpm = 5000, modeSets = 0, abs = 'realistic' }
local function setMode(k) local m = MODES[k] CT.mode, CT.esc, CT.tc, CT.lock, CT.modeSets = k, m.on, m.on, m.lock, CT.modeSets + 1 end
local CTRL = {
  driveModes = { getCurrentDriveModeKey = function() return CT.mode end, getDriveModeData = function(k) return MODES[k] end, setDriveMode = setMode },
  yawControl = { setParameters = function(p) if p.isEnabled ~= nil then CT.esc = p.isEnabled == 'default' or p.isEnabled end end },
  tractionControl = { setParameters = function(p) if p.isEnabled ~= nil then CT.tc = p.isEnabled == 'default' or p.isEnabled end end },
  electronicSplitShaftLock = { setParameters = function(p) if p.minimumLock then CT.lock = p.minimumLock end end },
  twoStepLaunch = { setParameters = function(p) if p.isEnabled ~= nil then CT.launch = p.isEnabled end if p.launchRPM then CT.rpm = p.launchRPM end end },
}
controller = { getController = function(n) return CTRL[n] end }
v = { data = { controller = { { fileName = 'driveModes', enabledModes = { 'comfort', 'sport', 'arsenic', 'off' } } } },
  config = { model = 'vivace', partConfigFilename = 'vehicles/vivace/ardente_track.pc', vars = { ['$brakebias'] = 0.6 },
    partsTree = { path = '/', chosenPartName = 'vivace', children = { { path = '/body/', chosenPartName = 'ardente_body' } } } } }
powertrain = { getDevicesByCategory = function() return { { maxRPM = 7000 } } end }
wheels.setABSBehavior = function(b) CT.abs = b end
wheels.resetABSBehavior = function() CT.abs = 'realistic' end
-- what the game's own vehicle reset does before our next frame
local function gameReset()
  A.onReset()
  for _, w in pairs(W) do w.brakeTorque = w.initialBrakeTorque end
  setMode(CT.mode) -- controller.resetLastStage: the drive mode again
end

-- game engine ----------------------------------------------------------------------------
local veh = { getId = function() return 7 end, queueLuaCommand = function(_, s) VQ[#VQ + 1] = s end,
  getVelocity = function() return { x = 20, y = 0, z = 0 } end, getJBeamFilename = function() return 'vivace' end,
  partConfig = 'vehicles/vivace/ardente_track.pc' }
local REC = false
coDriverAnalysis = { isRecording = function() return REC end, getResult = function() return nil end }
getPlayerVehicle = function() return veh end
getObjectByID = function(id) return id == 7 and veh or (id == 5 and { queueLuaCommand = function(_, s) OLDQ[#OLDQ + 1] = s end }) or nil end
core_environment = { getState = function() return { time = 0, temperatureC = 20 } end }
guihooks.message = function(text) MSG[#MSG + 1] = text end
local lastWrite
local jw = jsonWriteFile
jsonWriteFile = function(f, o, p) lastWrite = o return jw(f, o, p) end
FS.renameFile = function(_, a, b) writeText(b, jsonEncode(readJSON(a))) removeFileJS(a) end
local DIR = 'settings/coDriverCoach/engineer/'
mkdirJS(DIR)
writeText(DIR .. 'bridge.json', jsonEncode({ t = os.time(), llm = true, stt = true, tts = true }))
local E = dofile(SRC)
coDriverEngineer = E
E.onExtensionLoaded()

local function runGE() local q = GEQ GEQ = {} for _, s in ipairs(q) do assert(load(s))() end end
local function runVeh() local q = VQ VQ = {} for _, s in ipairs(q) do assert(load(s))() end runGE() end
local function frames(secs, fn)
  for _ = 1, math.floor(secs * 60 + 0.5) do A.updateGFX(1 / 60) if fn then fn() end end
  runGE()
end
local function torque(name) for _, w in pairs(W) do if w.name == name then return w.brakeTorque end end end
local function total() local s = 0 for _, w in pairs(W) do s = s + w.brakeTorque end return s end
local function lastMsg() return MSG[#MSG] or '' end

-- 1. clamping ----------------------------------------------------------------------------
local c = A.clampAdjust({ bias = 0.5, brake = 2, ffb = 0.1 })
check('clamp high bias/brake, low ffb', near(c.bias, 0.10) and near(c.brake, 1.1) and near(c.ffb, 0.6), serialize(c))
c = A.clampAdjust({ bias = -1, brake = 0, ffb = 9 })
check('clamp low bias/brake, high ffb', near(c.bias, -0.10) and near(c.brake, 0.8) and near(c.ffb, 1.3), serialize(c))
c = A.clampAdjust({ bias = 'x', brake = 0 / 0 })
check('garbage values are dropped', next(c) == nil, serialize(c))
c = A.clampAdjust({ awdLock = 0.9, launchRPM = 9999, esc = false, tc = 'yes', abs = true, driveMode = 'Sport' })
check('electronics clamped', near(c.awdLock, 0.6) and c.launchRPM == 6300 and c.esc == false and c.tc == nil and c.abs == true and c.driveMode == 'sport',
  serialize(c))
check('unknown drive mode dropped', A.clampAdjust({ driveMode = 'eco' }).driveMode == nil)
check('no electronics the car lacks', A.clampAdjust({ awdLock = 0.2 }, { modes = {} }).awdLock == nil)
local cF, cR = A.biasCoefs(2 / 3, 0.02)
check('bias +2 points keeps total torque', near(4000 * cF + 2000 * cR, 6000) and cF > 1 and cR < 1, cF .. ' ' .. cR)
check('bias 0 is 1/1', select(1, A.biasCoefs(2 / 3, 0)) == 1)

-- 2. status carries the adjustment state; an answer with actions reaches the vehicle --------
A.sendStatus()
runGE()
local st = E.getStatus()
check('status has adjust', st and st.adjust and near(st.adjust.stockFrontPct, 66.7, 0.05) and st.adjust.ffbDevice == true,
  st and serialize(st.adjust))
E.ask('more front bias and lighter wheel', 'drive')
local req = lastWrite
check('ask sends the adjustment state', req and req.type == 'ask' and req.data and req.data.adjust and req.data.adjust.biasShift == 0)
writeText(DIR .. 'res_' .. req.id .. '.json', jsonEncode({ id = req.id, text = 'Copy, two points forward and lighter wheel.',
  source = 'haiku', actions = { { kind = 'bias', value = 2 }, { kind = 'ffb', value = 90 } } }))
E.onUpdate(0.05)
check('answer shown', lastMsg():find('two points forward', 1, true) ~= nil, lastMsg())
check('one command queued to the vehicle', #VQ == 1 and VQ[1]:find('coDriverRec.adjust', 1, true) ~= nil, VQ[1])
-- a review-mode answer never changes the car
E.ask('more front bias', 'review')
local req2 = lastWrite
writeText(DIR .. 'res_' .. req2.id .. '.json', jsonEncode({ id = req2.id, text = 'x', actions = { { kind = 'bias', value = 4 } } }))
E.onUpdate(0.05)
check('review answers carry no car changes', #VQ == 1)

-- 3. queued until the wheel is straight and the brake is off ------------------------------
electrics.values.brake_input = 0.6
runVeh()
check('queued message', lastMsg():find('next straight', 1, true) ~= nil, lastMsg())
check('nothing applied yet', torque('FL') == 2000 and hydros.wheelFFBForceCoef == 250)
frames(1)
check('brake held: still waiting', torque('FL') == 2000 and A.getAdjust().waiting == true)
electrics.values.brake_input, electrics.values.steering_input = 0, 0.3
frames(1)
check('steering: still waiting', torque('FL') == 2000)
electrics.values.steering_input = 0.02
local coefs, t0 = {}, nil
frames(2.5, function() coefs[#coefs + 1] = hydros.wheelFFBForceCoef end)
cF, cR = A.biasCoefs(2 / 3, 0.02)
check('front torque up, rear down', near(torque('FL'), 2000 * cF) and near(torque('RR'), 1000 * cR), torque('FL') .. ' ' .. torque('RR'))
check('total brake torque unchanged', near(total(), 6000), total())
check('applied message', MSG[#MSG]:find('set, brake bias', 1, true) ~= nil and MSG[#MSG]:find('force feedback 90', 1, true) ~= nil, MSG[#MSG])

-- 4. the force feedback ramp ---------------------------------------------------------------
local first, last, maxStep, mono = nil, nil, 0, true
for i = 2, #coefs do
  local d = coefs[i] - coefs[i - 1]
  if d ~= 0 then first = first or i last = i end
  if d > 1e-9 then mono = false end
  maxStep = math.max(maxStep, math.abs(d))
end
local rampSecs = first and (last - first + 1) / 60 or 0
check('ffb ends at 90% of the binding', near(hydros.wheelFFBForceCoef, 225) and near(hydros.wheelFFBForceCoefLowSpeed, 22.5), hydros.wheelFFBForceCoef)
check('ffb ramps over about a second', rampSecs > 0.9 and rampSecs < 1.1, rampSecs)
check('ffb ramp is monotonic with small steps', mono and maxStep < 25 * 1.5 / 60 + 1e-6, string.format('max step %.3f of 25', maxStep))

-- 5. brake strength on top of the bias, clamped --------------------------------------------
E.applyActions({ { kind = 'brake', value = 200 } })
runVeh()
frames(0.5)
check('brake strength clamped to 110%', near(total(), 6600, 1e-6) and near(torque('FL'), 2000 * cF * 1.1), total())

-- 6. "undo": back to stock on the next straight ---------------------------------------------
E.applyActions({ { kind = 'revert' } })
runVeh()
frames(2)
local a = A.getAdjust()
check('undo: brakes stock', torque('FL') == 2000 and torque('RR') == 1000)
check('undo: ffb back exactly on the binding value', hydros.wheelFFBForceCoef == 250 and hydros.wheelFFBForceCoefLowSpeed == 25, hydros.wheelFFBForceCoef)
check('undo: state stock', a.biasShift == 0 and a.brakePct == 100 and a.ffbPct == 100 and not a.waiting, serialize(a))
check('nothing left to look after', not coDriverRecShared.adj.ffbWritten and not coDriverRecShared.adj.want)

-- 7. the game re-reads the binding mid-adjustment: its value wins ---------------------------
E.applyActions({ { kind = 'ffb', value = 120 } })
runVeh()
frames(2)
check('ffb up to 120%', near(hydros.wheelFFBForceCoef, 300))
hydros.wheelFFBForceCoef, hydros.wheelFFBForceCoefLowSpeed = 180, 18 -- options: new strength
frames(0.5)
check('binding change wins', hydros.wheelFFBForceCoef == 180 and A.getAdjust().ffbPct == 100)
check('told the driver', lastMsg():find('its settings changed', 1, true) ~= nil, lastMsg())

-- 8. a vehicle reset keeps everything ----------------------------------------------------------
E.applyActions({ { kind = 'bias', value = -4 }, { kind = 'ffb', value = 70 } })
runVeh()
frames(2)
check('bias rearward applied', torque('RL') > 1000 and near(total(), 6000))
local rlBefore = torque('RL')
gameReset()
check('the game reset put stock torque back', torque('RL') == 1000)
frames(0.1)
check('reset: bias applied again', near(torque('RL'), rlBefore) and near(total(), 6000), torque('RL'))
check('reset: ffb kept', near(hydros.wheelFFBForceCoef, 126) and near(hydros.wheelFFBForceCoefLowSpeed, 12.6), hydros.wheelFFBForceCoef)
check('reset message', lastMsg():find('still set after the reset', 1, true) ~= nil, lastMsg())

-- 8b. electronics: drive mode, aids, launch, centre lock; kept through a reset ---------------------
E.applyActions({ { kind = 'driveMode', value = 'sport' }, { kind = 'tc', value = false }, { kind = 'abs', value = false },
  { kind = 'launchRPM', value = 4500 }, { kind = 'awdLock', value = 30 } })
check('electronics queued, not applied', CT.mode == 'arsenic' and CT.tc == true)
runVeh()
frames(1)
check('drive mode sport', CT.mode == 'sport')
check('tc off on top of the mode', CT.tc == false and CT.esc == true)
check('abs off', CT.abs == 'off')
check('launch rpm 4500, centre lock 0.3', CT.rpm == 4500 and near(CT.lock, 0.3))
check('applied message names them', lastMsg():find('Sport mode', 1, true) and lastMsg():find('traction control off', 1, true)
  and lastMsg():find('ABS off', 1, true) and lastMsg():find('centre lock 30%', 1, true), lastMsg())
gameReset()
check('the game reset put the mode values back', CT.tc == true and near(CT.lock, 0.25))
frames(0.1)
check('reset: electronics applied again', CT.mode == 'sport' and CT.tc == false and near(CT.lock, 0.3) and CT.abs == 'off')
-- one electronics change back to the car's own: the mode's value returns, the rest stay
E.applyActions({ { kind = 'tc', value = 'stock' } })
runVeh()
frames(1)
check('tc back to the mode, others kept', CT.tc == true and near(CT.lock, 0.3) and CT.abs == 'off' and CT.mode == 'sport')
-- the driver picks a drive mode: theirs wins over our electronics (ABS is not part of a mode)
setMode('comfort')
frames(0.1)
local t = A.getAdjust().targets
check('driver mode wins', CT.mode == 'comfort' and t.driveMode == nil and t.awdLock == nil and t.launchRPM == nil and t.abs == false, serialize(t))
check('told the driver', lastMsg():find('drive mode choice', 1, true) ~= nil, lastMsg())

-- 8c. the game engine keeps the set for this car and session ----------------------------------
local before = serialize(A.getAdjust().targets)
coDriverRecShared = { damage = {} } -- the car reloaded: a fresh vehicle VM (as the module top level sets it up)
for _, w in pairs(W) do w.brakeTorque = w.initialBrakeTorque end
hydros.wheelFFBForceCoef, hydros.wheelFFBForceCoefLowSpeed = 180, 18
CT.abs = 'realistic'
-- as the game does it: the car vanishes (-1, -1) and the recording ends, then the same car comes back
REC = true E.onUpdate(1.0)
E.onVehicleSwitched(-1, -1)
REC = false E.onUpdate(1.0)
E.onVehicleSpawned(7)
E.onVehicleSwitched(-1, 7)
E.onUpdate(1.6) E.onUpdate(1.0)
runVeh() runVeh() -- the GE asks the car for a status, sees no set, sends it back
frames(1.5)
check('reload: the same set again', serialize(A.getAdjust().targets) == before and near(hydros.wheelFFBForceCoef, 126) and CT.abs == 'off',
  serialize(A.getAdjust().targets))
check('reload message', lastMsg():find('still set after the reload', 1, true) ~= nil, lastMsg())
-- a reload and no spawn hook: the next status notices and puts it back
coDriverRecShared = { damage = {} }
for _, w in pairs(W) do w.brakeTorque = w.initialBrakeTorque end
hydros.wheelFFBForceCoef, hydros.wheelFFBForceCoefLowSpeed = 180, 18 -- a reload reads the binding again
E.onUpdate(6)
A.sendStatus() runGE() runVeh() frames(1.5)
check('status safety net restores', serialize(A.getAdjust().targets) == before, serialize(A.getAdjust().targets))
-- the session ends (Review, coach off): back to stock
REC = true E.onUpdate(1.0)
REC = false E.onUpdate(1.0)
runVeh()
frames(2)
check('session end: stock', next(A.getAdjust().targets) == nil and torque('RL') == 1000 and hydros.wheelFFBForceCoef == 180 and CT.abs == 'realistic',
  serialize(A.getAdjust().targets))
check('session end message', lastMsg():find('session over', 1, true) ~= nil, lastMsg())
-- a different car (config) in the same slot clears the kept set
E.applyActions({ { kind = 'brake', value = 95 } })
runVeh() frames(1)
v.config.partConfigFilename = 'vehicles/vivace/rally.pc' -- another config in the same slot
E.onVehicleSpawned(7)
coDriverRecShared = { damage = {} }
E.onUpdate(6) runVeh() runVeh()
check('other config: nothing restored', #VQ == 0 and next(A.getAdjust().targets) == nil)
local id1 = A.getAdjust().carId
v.config.vars['$brakebias'] = 0.62 -- the same file with other tuning is another car too
v.config.partConfigFilename = 'vehicles/vivace/ardente_track.pc'
check('tuning changes the car id', A.getAdjust().carId ~= id1 and A.getAdjust().carId:find('ardente_track', 1, true) ~= nil, A.getAdjust().carId)
v.config.vars['$brakebias'] = 0.6
for _, w in pairs(W) do w.brakeTorque = w.initialBrakeTorque end

-- 9. switching away from a car reverts it (silently) ------------------------------------------
E.applyActions({ { kind = 'brake', value = 90 } })
runVeh()
frames(1)
local n = #MSG
E.onVehicleSwitched(7, 9)
runVeh()
check('switch queues an immediate revert to the old car', #VQ == 0 and torque('FL') == 2000, torque('FL'))
check('switch shows no message', #MSG == n)
E.onVehicleSwitched(5, 7)
check('switch from another car reverts that one', OLDQ[1] and OLDQ[1]:find('revert("switch", true)', 1, true) ~= nil)

-- 10. a car with brakes on one axle only can't take bias ---------------------------------------
W[2].initialBrakeTorque, W[2].brakeTorque, W[3].initialBrakeTorque, W[3].brakeTorque = 0, 0, 0, 0
A.adjust({ bias = 0.04 })
check('no bias on a one-axle-brake car', not A.getAdjust().waiting and A.getAdjust().canBias == false)

print(string.format('%d checks, %d failed', checks, fails))
if fails > 0 then error('t_adjust failed') end
