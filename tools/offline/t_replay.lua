-- The continuous replay's state machine with a mocked core_replay: playback across three replay
-- files (the last after a gap), turn-by-turn steps, and the end of the recording.
-- SRC=<session file>: a real session (its corners give the turns). MODE=damaged makes the middle
-- file fail to load (as a file cut short by the rotation did); MODE=refused makes it load without
-- ever playing (how BeamNG 0.40 refuses a file); MODE=oldversion makes it a file recorded before
-- this game version was first seen (skipped without loading). Run from an empty folder with
-- settings/coDriverCoach/.
local s = readJSON(SRC)
local T0 = s.samples[1][1] or s.samples[1]['1']
local last = s.samples[#s.samples][1] or s.samples[#s.samples]['1']
local span = (last - T0) / 3
mkdirJS('replays/codriver')
for _, f in ipairs({ 'a', 'b', 'c' }) do writeText('replays/codriver/' .. f .. '.rpl', 'x') end
-- part b covers [t0b, t0b + span - 3), part c starts 3 s later: a gap
s.parts = { { file = 'replays/codriver/a.rpl', t0 = T0, offset = -T0 }, { file = 'replays/codriver/b.rpl', t0 = T0 + span, offset = -(T0 + span) },
  { file = 'replays/codriver/c.rpl', t0 = T0 + 2 * span, offset = -(T0 + 2 * span) } }
local lens = { ['replays/codriver/a.rpl'] = span, ['replays/codriver/b.rpl'] = span - 3, ['replays/codriver/c.rpl'] = span + 1 }
writeText('settings/coDriverCoach/last_session.json', jsonEncode(s))
if MODE == 'oldversion' or MODE == 'refused' then
  beamng_versiond = '0.40.1.0'
  writeText('settings/coDriverCoach/game_versions.json', jsonEncode({ ['0.40'] = 2000 }))
  FS.stat = function(_, f) return { modtime = (MODE == 'oldversion' and f:find('b.rpl', 1, true)) and 1000 or 3000, filesize = 1 } end
  A.onExtensionLoaded()
end
-- mocks
local R = { file = nil, pos = 0, paused = true, loads = {} }
core_replay = {
  loadFile = function(f)
    table.insert(R.loads, f:match('(%a)%.rpl'))
    if MODE == 'damaged' and f:find('b.rpl', 1, true) then return { success = false, filename = f, message = 'Replay stream failed to play' } end
    if MODE == 'refused' and f:find('b.rpl', 1, true) then return { success = true, filename = f, code = 'queued' } end
    R.file, R.pos, R.paused, R.fresh = f, 0, true, true
    return { success = true, filename = f }
  end,
  getTotalSeconds = function() return lens[R.file] or 0 end,
  seek = function(frac) R.pos = frac * (lens[R.file] or 0) end,
  pause = function(p) R.paused = p end, setSpeed = function() end, stop = function() R.file = nil end,
  getState = function() return R.file and 'playback' or 'inactive' end, state = {},
}
core_camera = { setByName = function() end, getActiveCamName = function() return 'orbit' end }
getPlayerVehicle = function() return nil end
function quat(q) return q end
spawn = { safeTeleport = function() end }
local function tick(dt)
  if R.file then
    if not R.fresh and not R.paused then R.pos = math.min(R.pos + dt, lens[R.file]) end
    R.fresh = false
    A.onReplayStateChanged({ state = 'playback', totalSeconds = lens[R.file], positionSeconds = R.pos, paused = R.paused })
  end
  A.onUpdate(dt, dt)
end
A.loadLast()
local res = A.getResult()
print('mode', MODE or 'ok', 'corners', #res.corners, 'hasReplay', res.hasReplay, 'parts', #s.parts, string.format('span %.1f s', span))
local function state() local st = GUI.CoDriverAnalysisState or {} return st.replay or {} end
A.replayCorner(1)
local seen, msgs = {}, {}
for _ = 1, math.floor((last - T0 + 10) / 0.1) do
  tick(0.1)
  local r = state()
  if r.corner and seen[#seen] ~= r.corner then seen[#seen + 1] = r.corner end
  if r.msg and msgs[#msgs] ~= r.msg then msgs[#msgs + 1] = r.msg end
end
print('files loaded in order:', table.concat(R.loads, ' '))
print('turns seen in order:', table.concat(seen, ' '))
print('messages:', table.concat(msgs, ' | '))
print('paused at end:', R.paused, string.format('t %.1f of %.1f', state().t or -1, last))
-- steps: from the start, next twice, then prev
R.loads = {}
A.replayCorner(1)
for _ = 1, 5 do tick(0.1) end
local c1 = state().corner
A.replayStep(1) for _ = 1, 3 do tick(0.1) end
local c2 = state().corner
A.replayStep(1) for _ = 1, 3 do tick(0.1) end
local c3 = state().corner
A.replayStep(-1) for _ = 1, 3 do tick(0.1) end
local c4 = state().corner
print('step test: start', c1, 'next', c2, 'next', c3, 'prev', c4, 'loads', table.concat(R.loads, ' '))
A.exitReplay()
print('after exit, mode:', (GUI.CoDriverAnalysisState or {}).mode)
local blocked = 0
for _, c in ipairs(A.getResult().corners) do if not c.hasReplay then blocked = blocked + 1 end end
print('corners without a replay now:', blocked, 'damaged list:', readJSON('settings/coDriverCoach/damaged_replays.json') and 'written' or 'none')
