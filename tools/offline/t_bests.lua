-- Personal bests across drives (Phase D), on a real session with laps (SRC=<session file>, a route
-- id in ROUTE, default r1): the best lap's file is made from the archive (ensureBestEver), the
-- review sees it (same drive), and a best ever taken from another lap lines up with that lap.
-- Run from an empty folder with settings/coDriverCoach/.
local route = ROUTE or 'r1'
local s = readJSON(SRC)
local name = 'test_session'
mkdirJS('settings/coDriverCoach/sessions')
writeText('settings/coDriverCoach/sessions/' .. name .. '.json', jsonEncode(s))
local best
for _, l in ipairs(s.laps or {}) do if l.route == route and l.valid and (not best or l.time < best.time) then best = l end end
writeText('settings/coDriverCoach/sessions/index.json', jsonEncode({ { name = name, level = s.level, model = s.model, date = s.date, bestLap = best.time } }))
writeText('settings/coDriverCoach/last_session.json', jsonEncode(s))
local fails = 0
local function check(ok, what) print((ok and 'ok   ' or 'FAIL ') .. what) if not ok then fails = fails + 1 end end

check(A.ensureBestEver(s.level, route, best.time) == true, 'backfill from the archive: ' .. route .. ' ' .. best.time)
local ev = A.loadBestEver(s.level, route)
check(ev and #ev.pts.x > 300 and math.abs(ev.time - best.time) < 0.001, string.format('best file: %d points, %.3f s', ev and #ev.pts.x or 0, ev and ev.time or -1))
check(ev and ev.pts.t[#ev.pts.t] <= best.time + 0.1 and ev.pts.t[#ev.pts.t] >= best.time - 0.6, string.format('last point at %.2f s of %.3f', ev and ev.pts.t[#ev.pts.t] or -1, best.time))
check(A.ensureBestEver(s.level, route, best.time) == true, 'second call keeps the file')

A.loadLast()
local L = A.getResult().laps
check(L and L.bestEver and L.bestEver.same, 'review: best ever found, from this drive')
check(L.bestEver and #L.bestEver.tAt == L.cells + 1 and #L.bestEver.vAt == L.cells + 1, 'best ever has time and speed at every cell boundary')

-- a best ever from another lap (lap 3 here, as if it came from another drive)
local other
for _, l in ipairs(s.laps) do if l.route == route and l.valid and l ~= best and (not other or l.time < other.time) then other = l end end
check(A.saveBestEver(s.level, route, other, s.samples, 'other_drive', s.model, '2026-01-01 10:00'), 'saved lap ' .. other.n .. ' as the best ever')
A.loadLast()
L = A.getResult().laps
local be = L.bestEver
local lapOther
for _, l in ipairs(L.list) do if math.abs(l.time - other.time) < 0.001 then lapOther = l end end
check(be and not be.same and math.abs(be.time - other.time) < 0.001, 'review: best ever from another drive, ' .. (be and be.time or -1))
local worst = 0
for k = 1, L.cells + 1 do
  local a, b = be.tAt[k], lapOther.tAt[k]
  if a >= 0 and b >= 0 then worst = math.max(worst, math.abs(a - b)) end
end
check(worst < 0.15, string.format('its cell times match lap %d within %.3f s', other.n, worst))
print(string.format('best lap L%d against the best ever (L%d): lost %.2f s in %d stretches, gained %.2f s in %d', best.n, other.n, be.lost, #be.stretches, be.gained, #be.ahead))
for _, x in ipairs(be.ahead) do print('  quicker: ' .. x.where .. string.format(' %.2f s', x.gain)) end
check(be.gained - be.lost > 0, 'the drive\'s best lap comes out quicker than the slower best ever')
check(#be.line.x > 100, 'line for the map: ' .. #be.line.x .. ' points')
print(fails == 0 and 'ALL PASSED' or (fails .. ' FAILED'))
