-- Balance and measured power (Phase E) on a real session (SRC=<session file>): how much of the drive
-- is flagged understeer / oversteer, the fitted steering gain, every corner's balance note, whether
-- the spins and lost cars have oversteer flagged, and measured power against the car's listed power.
-- Run from an empty folder with settings/coDriverCoach/.
local s = readJSON(SRC)
writeText('settings/coDriverCoach/last_session.json', jsonEncode(s))
local fails = 0
local function check(ok, what) print((ok and 'ok   ' or 'FAIL ') .. what) if not ok then fails = fails + 1 end end

check(A.loadLast(), 'analysis ran')
local R = A.getResult()
local P = R.points
local n, u, o = #P.bal, 0, 0
for i = 1, n do
  if P.bal[i] == 1 then u = u + 1 elseif P.bal[i] == 2 then o = o + 1 end
end
print(string.format('%d points: understeer %d (%.1f%%), oversteer %d (%.1f%%)', n, u, 100 * u / n, o, 100 * o / n))
check(n > 0 and (u + o) / n < 0.25, 'most of the drive is neutral')
local notes, spins, spinsSeen = 0, 0, 0
for _, c in ipairs(R.corners) do
  if c.balance then notes = notes + 1 end
  if c.incident == 'spin' or c.incident == 'lost' then -- 'lost' (far too slow) isn't always a slide: shown, not counted
    local seen = false
    for i = c.i0, c.i1 do if P.bal[i] == 2 then seen = true end end
    if c.incident == 'spin' then
      spins = spins + 1
      if seen then spinsSeen = spinsSeen + 1 end
    end
    print(string.format('  corner %d %s: oversteer flagged %s; %s', c.id, c.incident, tostring(seen), tostring(c.balance)))
  end
end
print(string.format('%d of %d corners have a balance note', notes, #R.corners))
for i, id in ipairs(R.order) do
  if i > 8 then break end
  for _, c in ipairs(R.corners) do if c.id == id then print(string.format('  corner %d loss %.2f: %s', c.id, c.loss, tostring(c.balance))) end end
end
check(spinsSeen == spins, string.format('oversteer flagged in %d of %d spins', spinsSeen, spins))
local m = R.model or {}
print('steering gain: ' .. tostring(m.steerGain) .. (m.steerGain and '' or ' (no steering input recorded, e.g. an AI drive: understeer not judged)'))
print(string.format('power: listed %s kW, measured %s kW at the wheels at %s km/h', tostring(m.powerKW), tostring(m.powerMeasuredKW), tostring(m.powerMeasuredKmh)))
if m.powerKW and m.powerMeasuredKW then
  local r = m.powerMeasuredKW / m.powerKW
  check(r > 0.6 and r < 1.1, string.format('measured is %.0f%% of listed', r * 100))
end

-- a made-up slide: through the apex of the costliest clean corner, the car's nose turns up to 25
-- degrees further into the turn than it travels (the rear stepping out); the slide must be flagged
local pick
for _, id in ipairs(R.order) do
  for _, c in ipairs(R.corners) do if c.id == id and not c.incident and not pick then pick = c end end
end
local tA = P.t[pick.iApex]
local sgn = pick.dir == 'left' and 1 or -1
local rotated = 0
for _, smp in ipairs(s.samples) do
  local dt = smp[1] - tA
  if dt > -0.8 and dt < 0.8 then
    local a = math.rad(25) * (1 - math.abs(dt) / 0.8) * sgn
    local hx, hy = smp[8], smp[9]
    smp[8], smp[9] = hx * math.cos(a) - hy * math.sin(a), hx * math.sin(a) + hy * math.cos(a)
    rotated = rotated + 1
  end
end
writeText('settings/coDriverCoach/last_session.json', jsonEncode(s))
A.loadLast()
local R2 = A.getResult()
local flagged = 0
for _, c in ipairs(R2.corners) do
  if math.abs(R2.points.t[c.iApex] - tA) < 1 then
    for i = c.i0, c.i1 do if R2.points.bal[i] == 2 then flagged = flagged + 1 end end
    print(string.format('made-up slide at corner %d (%s, %d samples turned): %d points flagged oversteer; %s', c.id, pick.dir, rotated, flagged, tostring(c.balance)))
  end
end
check(flagged >= 2, 'the made-up slide is flagged')
print(fails == 0 and 'ALL PASSED' or (fails .. ' FAILED'))
