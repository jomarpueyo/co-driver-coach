-- Co-Driver Coach: practice scenarios (split out of coDriverCoach.lua). One-click starts: map +
-- spawn point + car + surface, optionally with a GPS stage finish that ends the drive and opens
-- the debrief when you cross it.
-- new(C, S): C gives the coach's settings and helpers; S holds the state shared with the coach
-- (stage, stageResult, pendingScenario, menuOpen). Returns the scenario functions.
local M = {}
local min = math.min


local scenarios = {
  { id = 'italy_mountain', title = 'Mountain roads', map = 'Italy', level = 'italy', spawn = 'spawn_village_mountain',
    model = 'vivace', config = 'ardente_track', car = 'Vivace track', surface = 'tarmac',
    desc = 'Twisty mountain-village tarmac: hairpins, crests and stone walls.' },
  { id = 'italy_castle', title = 'Castle town to coast', map = 'Italy', level = 'italy', spawn = 'spawn_castle_town',
    model = 'covet', config = 'rally_asphalt', car = 'Covet rally (asphalt)', surface = 'tarmac',
    desc = 'Narrow old-town streets opening onto fast coastal roads.' },
  { id = 'italy_quarry', title = 'Quarry climb', map = 'Italy', level = 'italy', spawn = 'spawn_quarry_parking',
    model = 'sunburst2', config = 'rally_pro_gravel', car = 'Sunburst rally (gravel)', surface = 'gravel',
    desc = 'Loose quarry tracks and switchbacks.' },
  { id = 'utah_canyon', title = 'Canyon highway', map = 'Utah', level = 'Utah', spawn = 'spawn_west_highway',
    model = 'etk800', config = '856_ttsport_DCT', car = 'ETK 856 sport', surface = 'tarmac',
    desc = 'Fast sweepers through the canyon: braking points at speed.' },
  { id = 'utah_dirt', title = 'Desert dirt roads', map = 'Utah', level = 'Utah', spawn = 'spawn_campsite',
    model = 'pickup', config = 'd15_4wd_offroad_M', car = 'D15 off-road', surface = 'gravel',
    desc = 'Dusty back roads with big crests.' },
  { id = 'wcusa_redwood', title = 'Redwood forest', map = 'West Coast USA', level = 'west_coast_usa', spawn = 'spawns_redwood_forest',
    model = 'etk800', config = '844_track_M', car = 'ETK 844 track (manual)', surface = 'tarmac',
    desc = 'Flowing forest roads. Manual gearbox, so gear use gets graded.' },
  { id = 'wcusa_dirt', title = 'Dirt track', map = 'West Coast USA', level = 'west_coast_usa', spawn = 'spawns_dirttrack',
    model = 'sunburst2', config = 'rally_pro_gravel', car = 'Sunburst rally (gravel)', surface = 'gravel',
    desc = 'Short loose circuit: car control and smoothness practice.' },
  { id = 'ecusa_country', title = 'Country back roads', map = 'East Coast USA', level = 'east_coast_usa', spawn = 'spawns_farmhouse',
    model = 'covet', config = 'sport', car = 'Covet sport', surface = 'tarmac',
    desc = 'Rolling farm roads: commitment and corner entry.' },
  { id = 'jungle_rally', title = 'Jungle rally', map = 'Jungle Rock Island', level = 'jungle_rock_island', spawn = 'spawns_hill',
    model = 'vivace', config = 'ardente_rally', car = 'Vivace rally', surface = 'gravel',
    desc = 'Rally-style island roads with jumps and blind crests.' },
  { id = 'johnson_trails', title = 'Desert trails', map = 'Johnson Valley', level = 'johnson_valley', spawn = 'spawn_remote_pits',
    model = 'roamer', config = 'offroad', car = 'Roamer off-road', surface = 'gravel',
    desc = 'Slow technical trails: smoothness over speed.' },
  { id = 'att_rally', title = 'Rally stage', map = 'Automation Test Track', level = 'automation_test_track', spawn = 'spawns_rallytrack',
    model = 'bx', config = '240bx_coupe_rally_gravel', car = 'BX rally (gravel)', surface = 'gravel',
    desc = 'The test track\'s purpose-built gravel rally stage.' },
  { id = 'hirochi_circuit', title = 'Race circuit', map = 'Hirochi Raceway', level = 'hirochi_raceway', spawn = 'spawn_startline',
    model = 'vivace', config = 'ardente_race', car = 'Vivace race', surface = 'tarmac',
    desc = 'Lap the circuit: consistent braking points every lap.' },
}

M.new = function(C, S)
  local cfg, logTag = C.cfg, C.logTag
  local say, sayAt, pick, list, sendUI = C.say, C.sayAt, C.pick, C.list, C.sendUI
  local setSurface, endDrive, saveSettings = C.setSurface, C.endDrive, C.saveSettings

  local function findScenario(id)
    for _, s in ipairs(scenarios) do
      if s.id == id then return s end
    end
  end

  local function sendMenu()
    local list = {}
    for i, s in ipairs(scenarios) do
      list[i] = { id = s.id, title = s.title, map = s.map, car = s.car, surface = s.surface, desc = s.desc }
    end
    guihooks.trigger('CoDriverCoachMenu', {
      open = S.menuOpen, scenarios = list, last = cfg.lastScenario, ownCar = cfg.scenarioOwnCar, stageKm = cfg.stageKm,
      loading = S.pendingScenario and S.pendingScenario.sc.title or nil, level = getCurrentLevelIdentifier(),
      stage = S.stage and { km = S.stage.km } or nil,
    })
  end

  -- Pick a finish exactly `km` along the road from here and route the GPS to it.
  local function setupStage(km)
    local veh = getPlayerVehicle(0)
    local mapData = map.getMap()
    if not veh or not mapData or not mapData.nodes then return false end
    local nodes, pos, want = mapData.nodes, vec3(veh:getPosition()), km * 1000
    local start = map.findClosestRoad(pos)
    if not start then return false end
    local candidates = {}
    for id, n in pairs(nodes) do
      local d = (n.pos - pos):length()
      if d > want * 0.4 and d < want * 1.6 then candidates[#candidates + 1] = id end
    end
    for _ = 1, min(20, #candidates) do
      local path = map.getPath(start, candidates[math.random(#candidates)], 0.25, 1e4, 1, 1000)
      if path and path[2] and map.getPathLen(path) >= want then
        local n1, n2, xnorm = map.getNodesFromPathDist(path, want)
        local finish = (xnorm or 0) > 0.5 and n2 or n1
        if finish and nodes[finish] then
          S.stage = { node = finish, pos = vec3(nodes[finish].pos), km = km }
          core_groundMarkers.setPath(finish)
          return true
        end
      end
    end
    return false
  end

  local function cancelStage(silent)
    if not S.stage then return end
    S.stage = nil
    core_groundMarkers.setPath(nil)
    if not silent and cfg.chatter then say(list(pick('stage_cancelled'))) end
    sendUI()
  end

  local function finishStage()
    local km = S.stage.km
    S.stage = nil
    core_groundMarkers.setPath(nil)
    say({ 'over_finish' })
    S.stageResult = { km = km, time = C.drive() and C.drive().time or 0 }
    guihooks.message(string.format('Stage finished: %.0f km', km), 5, 'coDriverCoach')
    local ok, err = xpcall(endDrive, debug.traceback, false)
    if not ok then log('E', logTag, 'ending the stage failed: ' .. tostring(err)) end
  end

  -- Load a scenario. ownCar keeps the car you are driving; stageKm > 0 adds a GPS stage.
  local function loadScenario(id, ownCar, stageKm)
    local sc = findScenario(id)
    if not sc or S.pendingScenario then return end
    ownCar, stageKm = ownCar and true or false, tonumber(stageKm) or 0
    cfg.lastScenario, cfg.scenarioOwnCar, cfg.stageKm = id, ownCar, stageKm
    saveSettings()

    local p = { sc = sc, stageKm = stageKm, phase = 'loading', t = C.clock() }
    local veh = getPlayerVehicle(0)
    if ownCar and veh then
      p.model = veh:getJBeamFilename()
      local pc = veh.partConfig
      if type(pc) == 'string' and pc:sub(1, 1) == '{' then pc = deserialize(pc) end
      p.config = pc
    else
      p.model, p.config = sc.model, 'vehicles/' .. sc.model .. '/' .. sc.config .. '.pc'
    end

    cancelStage(true)
    if C.drive() then endDrive(false) end
    S.menuOpen = false
    S.pendingScenario = p
    setSurface(sc.surface, true)
    if getCurrentLevelIdentifier() == sc.level:lower() then
      p.phase, p.teleport = 'spawnCar', true -- same map: swap the car and teleport, no reload
    elseif not freeroam_freeroam or not freeroam_freeroam.startFreeroamByName(sc.level, sc.spawn) then
      S.pendingScenario = nil
      guihooks.message('Could not load ' .. sc.map .. '.', 5, 'coDriverCoach')
    elseif p.phase == 'loading' and cfg.chatter then
      say(list(pick('loading')))
    end
    sendMenu()
    sendUI()
  end

  local function restartScenario()
    if cfg.lastScenario == '' then return end
    if cfg.chatter then say(list(pick('restarting'))) end
    loadScenario(cfg.lastScenario, cfg.scenarioOwnCar, cfg.stageKm)
  end

  -- Steps a pending scenario along once the map is up: car, spawn point, stage. Also watches the stage finish.
  local function updateScenario()
    if S.stage then
      local left = core_groundMarkers.getPathLength()
      if left and left > 0 and cfg.chatter then -- halfway / one kilometer / five hundred to go
        local total = S.stage.km * 1000
        if not S.stage.saidHalf and left <= total * 0.5 then
          S.stage.saidHalf = true
          say(list(pick('halfway')), false, true)
        elseif total > 2000 and not S.stage.saidKm and left <= 1000 then
          S.stage.saidKm = true
          say(list(pick('one_km_to_go')), false, true)
        elseif not S.stage.said500 and left <= 500 and total > 1000 then
          S.stage.said500 = true
          say(list(pick('five_hundred_to_go')), false, true)
        end
      end
      local veh = getPlayerVehicle(0)
      if veh then
        local d = (vec3(veh:getPosition()) - S.stage.pos):length()
        S.stage.minDist = min(S.stage.minDist or math.huge, d)
        local arrived = d < 25
          or (left and left > 0 and left < 20 and S.stage.minDist < 200)  -- the GPS says we're there
          or (S.stage.minDist < 60 and d > S.stage.minDist + 20)            -- went past it, a little wide
        if arrived then finishStage() end
      end
    end

    local p = S.pendingScenario
    if not p then return end
    if C.clock() - p.t > 180 then -- something went wrong; don't stay stuck "loading"
      S.pendingScenario = nil
      sendMenu()
      return
    end
    if p.phase == 'loading' then return end -- advanced by onClientPostStartMission

    local veh = getPlayerVehicle(0)
    if not veh or C.clock() - p.t < 1.5 then return end
    if p.phase == 'spawnCar' then
      local same = veh:getJBeamFilename() == p.model and type(p.config) == 'string' and tostring(veh.partConfig) == p.config
      if not same then core_vehicles.replaceVehicle(p.model, { config = p.config }) end
      p.phase, p.t = 'teleport', C.clock()
    elseif p.phase == 'teleport' then
      if p.teleport then
        local sp = scenetree.findObject(p.sc.spawn)
        if sp then spawn.safeTeleport(veh, vec3(sp:getPosition()), quat(sp:getRotation()) * quat(0, 0, 1, 0)) end
      end
      p.phase, p.t = 'stage', C.clock()
    elseif p.phase == 'stage' then
      if p.stageKm > 0 and not setupStage(p.stageKm) then
        guihooks.message('No road long enough for a stage here; free drive instead.', 5, 'coDriverCoach')
      end
      if S.stage and cfg.chatter then -- "Stage ready. Three. Two. One. Go."
        sayAt(0.5, list(pick('stage_ready')))
        sayAt(2.0, list(pick('countdown_three', 'system_countdown3')))
        sayAt(3.0, list(pick('countdown_two', 'system_countdown2')))
        sayAt(4.0, list(pick('countdown_one', 'system_countdown1')))
        sayAt(5.0, list(pick('go', 'system_countdowngo')))
      end
      S.pendingScenario = nil
      if not S.stage and cfg.chatter then say(list(pick('scenario_ready'))) end
      guihooks.message(p.sc.title .. ' ready' .. (S.stage and string.format(': %.0f km stage, follow the GPS to the finish', S.stage.km) or ''), 6, 'coDriverCoach')
      sendMenu()
      sendUI()
    end
  end

  local function openMenu() S.menuOpen = true; sendMenu() end
  local function closeMenu() S.menuOpen = false; sendMenu() end
  local function toggleMenu() S.menuOpen = not S.menuOpen; sendMenu() end

  local function onClientPostStartMission()
    if S.pendingScenario and S.pendingScenario.phase == 'loading' then
      S.pendingScenario.phase, S.pendingScenario.t = 'spawnCar', C.clock()
    end
  end

  return { sendMenu = sendMenu, setupStage = setupStage, cancelStage = cancelStage, loadScenario = loadScenario,
    restartScenario = restartScenario, update = updateScenario, openMenu = openMenu, closeMenu = closeMenu,
    toggleMenu = toggleMenu, onClientPostStartMission = onClientPostStartMission }
end

return M
