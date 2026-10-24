-- Lap analysis on a saved session with laps (SRC=<session file>, default last_session.json):
-- prints each lap's time, sectors and delta to the best lap, the theoretical best, the turns
-- matched across laps, and checks that the time to the best lap at a lap's end matches its delta.
-- Then "where the time is" (10 m cells): for every complete lap against the best one, the cell
-- times add up to its gap and the time it lost in cells is at least that gap; the kept stretches
-- (losses minus gains) come within 0.1 s of the gap; the listed stretches are gains above 0, in
-- order of rate; the 10 m theoretical best is no slower than the 50 m one, which is no slower
-- than the best lap. A synthetic run of owners checks the flicker merge.
local src = SRC or 'settings/coDriverCoach/last_session.json'
if SRC then writeText('settings/coDriverCoach/last_session.json', jsonEncode(readJSON(SRC))) end
local t0 = os.clock()
A.loadLast()
local R = A.getResult() or {}
print(string.format('analysed in %.1f s: %s corners, err %s', os.clock() - t0, tostring(R.corners and #R.corners), tostring(R.error)))
local Lp = R.laps
if not Lp then print('no laps') return end
if OUT then writeText(OUT, jsonEncode(R)) end -- for the panel check (tools/offline/panel_stretches.js)
print('ref lap', Lp.ref, 'length', Lp.length, 'valid', Lp.valid, 'theoretical', Lp.theoretical, 'spread', Lp.spread,
  'best sectors', jsonEncode(Lp.sectors))
local P = R.points
local fails = 0
for li, l in ipairs(Lp.list) do
  local sum = 0
  for _, v in ipairs(l.sectors or {}) do sum = sum + v end
  -- delta at the lap's last point vs its delta to the best lap
  local endD = P.ld[l.i1]
  local top = {}
  for _, x in ipairs(l.top or {}) do top[#top + 1] = 'T' .. x.turn .. ' +' .. x.loss end
  print(string.format('L%d %.3f valid=%s delta=%s sectors=%s (sum %.2f) endDelta=%s top=%s replay=%s', l.n, l.time,
    tostring(l.valid), tostring(l.delta), jsonEncode(l.sectors), sum, tostring(endD), table.concat(top, ' '), tostring(l.hasReplay)))
  if l.valid and math.abs(sum - l.time) > 0.05 then fails = fails + 1 print('  FAIL sectors do not add up') end
  if l.valid and l.delta and endD and math.abs(endD - l.delta) > 0.6 then fails = fails + 1 print('  FAIL end delta far from lap delta') end
end
local matched, total = 0, 0
for _, c in ipairs(R.corners) do
  if c.lap then total = total + 1 if c.turn then matched = matched + 1 end end
end
print(string.format('turns %d; corners in laps %d, matched to a turn %d', #Lp.turns, total, matched))
for k = 1, math.min(6, #Lp.turns) do
  local tn = Lp.turns[k]
  print('  T' .. tn.id, tn.dir, 's=' .. math.floor(tn.s), 'best', tn.best, 'lap', tn.bestLap, 'times', jsonEncode(tn.times))
end

-- where the time is
local function fail(msg) fails = fails + 1 print('  FAIL ' .. msg) end
local best = Lp.list[Lp.ref]
print(string.format('theoretical: 10 m %s, 50 m %s, best lap %.3f; %d cells of %.2f m', tostring(Lp.theoretical10),
  tostring(Lp.theoretical), best.time, Lp.cells or 0, Lp.cellM or 0))
if not (Lp.theoretical10 and Lp.theoretical) then fail('no theoretical best')
else
  if Lp.theoretical10 > Lp.theoretical + 1e-9 then fail('10 m theoretical slower than the 50 m one') end
  if Lp.theoretical > best.time + 1e-9 then fail('50 m theoretical slower than the best lap') end
end
local function cellT(l, c)
  local a, b = l.tAt and l.tAt[c], l.tAt and l.tAt[c + 1]
  return a and b and a >= 0 and b >= 0 and b - a or nil
end
for _, l in ipairs(Lp.list) do if l.tAt then
  local sum, pos, complete = 0, 0, true
  for c = 1, Lp.cells do
    local a, b = cellT(l, c), cellT(best, c)
    if a and b then sum, pos = sum + (a - b), pos + math.max(0, a - b) else complete = false end
  end
  local gap = l.time - best.time
  local st = l.stretches or {}
  local parts = {}
  for _, x in ipairs(st) do
    parts[#parts + 1] = string.format('%s (%d-%d m, T%s) %.2f s %.3f/100m%s', x.where, x.s0, x.s1, tostring(x.turn), x.gain, x.rate,
      l == best and string.format(' by L%d', Lp.list[x.by].n) or '')
  end
  print(string.format('L%d gap %.2f: cells sum %.3f, lost in cells %.2f, stretches lost %s gained %s', l.n, gap, sum, pos,
    tostring(l.lost), tostring(l.gained)))
  for _, p in ipairs(parts) do print('    ' .. p) end
  for _, x in ipairs(l.ahead or {}) do print(string.format('    + quicker: %s %.2f s %.3f/100m', x.where, x.gain, x.rate)) end
  if #st > 8 or #(l.ahead or {}) > 3 then fail('too many stretches') end
  for k, x in ipairs(st) do
    if not (x.gain > 0) then fail('stretch gain not positive') end
    if k > 1 and (x.rate > st[k - 1].rate or (x.rate == st[k - 1].rate and x.s0 < st[k - 1].s0)) then fail('stretches not in order of rate') end
    if not (x.s1 > x.s0 and x.turn and x.where) then fail('stretch without place') end
  end
  if l ~= best and complete then
    if math.abs(sum - gap) > 0.01 then fail('cell times do not add up to the gap') end
    if pos < gap - 0.01 then fail('time lost in cells under the gap') end
    if math.abs((l.lost or 0) - (l.gained or 0) - gap) > 0.1 then fail('stretches lost - gained not within 0.1 s of the gap') end
  end
  if l == best and Lp.theoretical10 and (l.lost or 0) > l.time - Lp.theoretical10 + 0.01 then fail('best lap lost more than best - theoretical') end
end end

-- the flicker merge on a synthetic run of owners: 2 = A, 1 = B
local own = { 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 2, 2, 2, 2, 1, 2, 2, 2, nil, 2, 1, 1 }
local runs = A._ownerRuns(own, 22, function(c, o) return o == 1 and 0.01 or 0.02 end)
local got = {}
for _, r in ipairs(runs) do got[#got + 1] = r.o .. ':' .. r.c0 .. '-' .. r.c1 end
local want = '1:1-10 2:11-18 2:20-20 1:21-22'
print('flicker merge: ' .. table.concat(got, ' '))
if table.concat(got, ' ') ~= want then fail('flicker merge, want ' .. want) end
if math.abs(runs[1].gain - 0.10) > 1e-9 then fail('run gain') end

-- the engineer's lap context (ENG=<repo>/co_driver_coach/lua/ge/extensions/coDriverEngineer.lua),
-- studying lap 4: every other lap gets its 3 sharpest stretches, the studied one 6, in a few KB
if ENG then
  coDriverAnalysis = A
  core_environment = core_environment or { getState = function() return { time = 0, temperatureC = 20 } end }
  local E = dofile(ENG)
  local lc = E.getReviewContext(nil, 4).laps
  local size = #jsonEncode(lc)
  print(string.format('engineer laps context: %d bytes, theoretical %s', size, tostring(lc.theoreticalBest)))
  for _, x in ipairs(lc.laps) do
    print(string.format('  lap %d: %s', x.lap, x.whereLostVsBestLap or ('others quicker: ' .. tostring(x.otherLapsQuickerAt))))
    if not (x.whereLostVsBestLap or x.otherLapsQuickerAt) then fail('lap ' .. x.lap .. ' has no places') end
  end
  if size > 6000 then fail('engineer laps context over 6 KB') end
end
print(fails == 0 and 'PASS' or ('FAILS ' .. fails))
