-- Recce pacenotes (Phase F), with coDriverCoach/recce.lua as the extension: a recce lap on a 2 km
-- loop records the calls with their places; two later laps at different speeds get the same calls in
-- the same order, each corner once, the first corners of the next lap called before the line and not
-- again after it, and the coach's own calls held back where the recce covers the route. A partial
-- recce (the lap abandoned) covers only what was driven; clearing removes it.
-- Run from an empty folder with settings/coDriverCoach/.
local fails = 0
local function check(ok, what) print((ok and 'ok   ' or 'FAIL ') .. what) if not ok then fails = fails + 1 end end

local LEN = 2000
local corners = { 120, 400, 650, 900, 1300, 1700, 1950 } -- corner entries along the loop (m)
local pos = nil -- the lap timer: { n, prog } or nil
coDriverLaps = { getProgress = function()
  return pos and { level = 'test_level', route = 'r1', n = pos.n, prog = pos.prog, len = LEN, closed = true } or nil
end }

local said = {}
local C = { cfg = { recce = true }, log = function() end,
  say = function(words) said[#said + 1] = table.concat(words, ' ') end, announce = function() end }
local R = A.new(C)

-- the coach's own calls: each corner called when it is callDist ahead (what recce records)
local function coachCalls(prog, callDist, calledSet)
  for i, s in ipairs(corners) do
    for _, sc in ipairs({ s, s + LEN }) do
      local ahead = sc - prog
      if ahead <= callDist and ahead > 6 and not calledSet[sc] then
        calledSet[sc] = true
        R.onCall(ahead, { 'c' .. i }, 'corner ' .. i)
      end
    end
  end
end

-- drive: lap n from 0 to LEN at `step` m per tick; returns whether the coach was held back anywhere
local function drive(n, step, callDist, coach)
  local held, calledSet = 0, {}
  for prog = 0, LEN - 1, step do
    pos = { n = n, prog = prog }
    if R.update(callDist) then held = held + 1 elseif coach then coachCalls(prog, callDist, calledSet) end
  end
  return held
end

-- lap 1 normal (no recce yet): nothing held back
check(drive(1, 5, 120, false) == 0, 'no recce yet: the coach calls as usual')
R.arm(true)
drive(2, 5, 120, true) -- the recce lap: armed before it started
pos = { n = 3, prog = 0 } -- across the line: lap 2 is done and kept
R.update(120)
local d = jsonReadFile(A.path('test_level', 'r1'))
check(d and #d.calls == #corners, 'recce kept with ' .. (d and #d.calls or 0) .. ' calls')
check(d and d.covered == LEN, 'it covers the whole loop')

-- later laps at different speeds (and call distances): the stream of calls is the corners in route
-- order, each once per lap, with nothing missed or repeated across the line
local function stream(n0, step, callDist)
  said = {}
  local held = 0
  for n = n0, n0 + 1 do held = held + drive(n, step, callDist, true) end
  pos = { n = n0 + 2, prog = 0 } R.update(callDist)
  return said, held
end
local function inOrder(list)
  for i = 2, #list do
    local a, b = tonumber(list[i - 1]:sub(2)), tonumber(list[i]:sub(2))
    if b ~= a % #corners + 1 then return false end
  end
  return #list >= 2 * #corners - 1
end
local s1, held1 = stream(3, 7, 90)
local s2 = stream(6, 3, 150)
print('laps 3-4, 90 m: ' .. table.concat(s1, ','))
print('laps 6-7, 150 m: ' .. table.concat(s2, ','))
check(held1 > 0, 'the coach is held back where the recce covers the route')
check(inOrder(s1) and inOrder(s2), 'both runs: every corner in route order, once per lap, none missed or repeated')

-- a partial recce: the lap abandoned at 820 m covers only what was driven (its last call, for the
-- corner at 900 m, lies past that)
check(R.clear('test_level', 'r1'), 'cleared')
check(not FS:fileExists(A.path('test_level', 'r1')), 'the file is gone')
R.arm(true)
pos = { n = 10, prog = 0 } R.update(120)
local calledSet = {}
for prog = 0, 820, 5 do pos = { n = 10, prog = prog } R.update(120) coachCalls(prog, 120, calledSet) end
pos = nil R.update(120) -- the lap was dropped
d = jsonReadFile(A.path('test_level', 'r1'))
check(d and d.covered >= 815 and d.covered <= 825, 'partial recce covers ' .. tostring(d and d.covered) .. ' m')
pos = { n = 11, prog = 500 }
check(R.update(120), 'inside it the recce calls')
local inside, skip
for prog = 500, 830, 5 do pos = { n = 11, prog = prog } inside, skip = R.update(120) end
check(not inside and skip and skip > 0, 'just past it the coach skips the ' .. tostring(skip) .. ' m the recce already called')
pos = { n = 11, prog = 1500 }
check(not R.update(120), 'further on the coach calls as usual')
R.arm(true) pos = { n = 12, prog = 0 } R.update(120) pos = nil R.update(120)
check(jsonReadFile(A.path('test_level', 'r1')).covered >= 815, 'a too-short recce leaves the old one')

-- at the end of a lap past a partial recce, the line is the coach's: no wrapped recce calls
said = {}
for prog = 1800, 1995, 5 do pos = { n = 13, prog = prog } R.update(120) end
check(#said == 0, 'a partial recce makes no calls for the next lap before the line')

-- a route id given out again to another road (a different length): its old recce is ignored
local realLen = LEN
LEN = 3000
pos = { n = 14, prog = 500 }
check(not R.update(120), 'a recce of a different length (another road with this id) is ignored')
LEN = realLen

-- arming for one route doesn't record a lap on another
R.clear('test_level', 'r1')
R.arm(true, 'r2')
pos = { n = 15, prog = 0 } R.update(120)
check(R.state().recording == nil and R.state().armedRoute == 'r2', 'armed for r2: a lap of r1 is not recorded')
R.arm(false)
check(not R.state().armed, 'cancelled')
print(fails == 0 and 'ALL PASSED' or (fails .. ' FAILED'))
