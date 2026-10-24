-- Benchmark harness (copied into the installed mod by tools/perf_bench.sh, removed afterwards).
-- Fixed route: the AI drives waypoints taken from a recorded session, from the same start pose,
-- with a fixed free camera (constant rendering) or the driver camera. Records every frame's dtReal.
local M = {}
local frames, measuring = {}, false
local route, run, results = nil, nil, {}
local function now() return os.clock() end

local function stats(label)
  local n = #frames
  if n == 0 then return { label = label, n = 0 } end
  local s, c, over20, over25 = 0, {}, 0, 0
  for i, f in ipairs(frames) do s = s + f c[i] = f if f > 0.020 then over20 = over20 + 1 end if f > 0.025 then over25 = over25 + 1 end end
  table.sort(c)
  local function p(q) return c[math.max(1, math.min(n, math.floor(n * q + 0.5)))] * 1000 end
  return { label = label, n = n, fps = n / s, avgMs = s / n * 1000, p50 = p(0.5), p95 = p(0.95), p99 = p(0.99), max = c[n] * 1000,
    over20 = over20, over25 = over25 }
end

-- Waypoints every `step` metres of the session's driven path, from the first sample above 5 m/s, for `km`.
M.setRouteFromSession = function(path, km, step)
  local s = jsonReadFile(path)
  if type(s) ~= 'table' or type(s.samples) ~= 'table' then return 'no session' end
  local sm, i0 = s.samples, nil
  for i, x in ipairs(sm) do
    if math.sqrt(x[5] ^ 2 + x[6] ^ 2) > 5 then i0 = i break end
  end
  if not i0 then return 'no motion' end
  local a = sm[i0]
  local dir = vec3(a[5], a[6], 0):normalized()
  local wps, dist, nextAt, last = {}, 0, step, a
  for i = i0 + 1, #sm do
    local x = sm[i]
    dist = dist + math.sqrt((x[2] - last[2]) ^ 2 + (x[3] - last[3]) ^ 2)
    last = x
    if dist >= nextAt then
      local n1 = map.findClosestRoad(vec3(x[2], x[3], x[4]))
      if n1 and wps[#wps] ~= n1 then wps[#wps + 1] = n1 end
      nextAt = nextAt + step
      if dist > km * 1000 then break end
    end
  end
  route = { pos = vec3(a[2], a[3], a[4] + 0.3), rot = quatFromDir(dir, vec3(0, 0, 1)), wps = wps, camPos = vec3(a[2], a[3], a[4] + 250) }
  return #wps
end

-- One run: teleport to the start, camera ('fixed' or 'driver'), AI along the route, warm up, measure.
M.run = function(label, secs, cam, warm)
  if not route then return 'no route' end
  run = { label = label, secs = secs, cam = cam or 'fixed', warm = warm or 4, phase = 'tp', t = now() }
  return 'started'
end
M.busy = function() return run ~= nil end
M.results = function() return results end
M.clear = function() results = {} end

M.onUpdate = function(dtReal)
  if measuring and dtReal > 0 then frames[#frames + 1] = dtReal end
  if not run then return end
  local veh = getPlayerVehicle(0)
  local t = now()
  if run.phase == 'tp' then
    veh:queueLuaCommand('ai.setMode("disabled")')
    -- safeTeleport turns the rotation by quat(0, 0, 1, 0); pre-compensate so the car faces the route
    spawn.safeTeleport(veh, route.pos, quat(0, 0, -1, 0) * route.rot)
    run.phase, run.t = 'settle', t
  elseif run.phase == 'settle' and t - run.t > 2.5 then
    if run.cam == 'fixed' then
      commands.setFreeCamera()
      core_camera.setPosition(0, route.camPos)
      core_camera.setRotation(0, quatFromDir(vec3(0, 0.2, 1), vec3(0, 1, 0)))
    else
      core_camera.setByName(0, 'driver')
    end
    local wps = {}
    for i, w in ipairs(route.wps) do wps[i] = string.format('%q', w) end
    veh:queueLuaCommand('input.event("parkingbrake", 0, 1) ai.driveUsingPath{ wpTargetList = {' .. table.concat(wps, ',') .. '}, aggression = 0.5, avoidCars = "off", driveInLane = "off" }')
    run.phase, run.t = 'warm', t
  elseif run.phase == 'warm' and t - run.t > run.warm then
    frames, measuring = {}, true
    run.phase, run.t = 'measure', t
  elseif run.phase == 'measure' and t - run.t > run.secs then
    measuring = false
    local r = stats(run.label)
    r.speed = vec3(veh:getVelocity()):length()
    results[#results + 1] = r
    veh:queueLuaCommand('ai.setMode("disabled") input.event("parkingbrake", 1, 1)')
    run = nil
  end
end
return M
