-- Co-Driver Coach: recce pacenotes (split out of coDriverCoach.lua). Like a rally recce: drive a
-- timed route once with recce armed and the calls the coach makes are kept with their place on the
-- route; later laps on that route get exactly those calls at those places (the call timing setting
-- still decides how early), instead of calls worked out afresh each time.
-- new(C): C gives cfg, say(words), announce(text), log and the clock. Returns the recce functions.
-- Files: settings/coDriverCoach/routes/<level>_recce/<route>.json =
--   { version, level, route, len, closed, covered (m from the start line), date, calls = { { s, words, text } } }
local M = {}
local max, abs = math.max, math.abs

local DIR = 'settings/coDriverCoach/routes/'
local MIN_COVER = 300 -- a recce shorter than this isn't kept

function M.path(level, route)
  return DIR .. tostring(level) .. '_recce/' .. (tostring(route):gsub('[^%w_%-]', '_')) .. '.json'
end

function M.new(C)
  local R = {}
  local armed = false   -- record the next lap that starts: true (any route) or a route id
  local rec = nil       -- { level, route, n, len, closed, calls, maxProg }
  local cache = {}      -- path -> notes (false = none)
  local lastKey, lastProg = nil, 0
  local done = {}       -- calls made on this lap (index -> true)
  local nextDone = {}   -- the next lap's first corners, already called before the line
  local calledTo = nil  -- the furthest recce call on this lap (m along the route)

  local function load(level, route)
    local p = M.path(level, route)
    if cache[p] == nil then
      local d = FS:fileExists(p) and jsonReadFile(p)
      cache[p] = (type(d) == 'table' and type(d.calls) == 'table' and #d.calls > 0) and d or false
    end
    return cache[p] or nil
  end

  local function finish(reason)
    local r = rec
    rec = nil
    if not r then return end
    local covered = r.closed and r.lapDone and r.len or r.maxProg
    if covered < MIN_COVER or #r.calls == 0 then
      C.log('I', 'recce of ' .. tostring(r.route) .. ' not kept (' .. reason .. ', ' .. math.floor(covered) .. ' m)')
      return
    end
    table.sort(r.calls, function(a, b) return a.s < b.s end)
    local p = M.path(r.level, r.route)
    local dir = p:match('^(.*)/')
    if not FS:directoryExists(dir) then FS:directoryCreate(dir, true) end
    jsonWriteFile(p, { version = 1, level = r.level, route = r.route, len = r.len, closed = r.closed, covered = math.floor(covered),
      date = os.date('%Y-%m-%d %H:%M'), calls = r.calls }, true)
    cache[p] = nil
    C.log('I', string.format('recce of %s kept: %d calls over %d m', tostring(r.route), #r.calls, math.floor(covered)))
    if C.notify then C.notify(string.format('Recce kept: %d calls on this route. Later laps use them.', #r.calls)) end
  end

  -- the lap timer's position: { level, route, n, prog, len, closed } while a lap is timed, else nil
  local function progress()
    if not (coDriverLaps and coDriverLaps.getProgress) then return nil end
    local ok, p = pcall(coDriverLaps.getProgress)
    return ok and p or nil
  end

  -- Called each path update before the coach's own calls (also when stopped, so a lap that ends is
  -- seen). Makes the recce calls that are due (only when moving) and returns true when the recce
  -- covers this part of the route (the coach then makes no corner calls); past the end of a partial
  -- recce, also how far ahead the recce has already called (the coach skips those corners).
  function R.update(callDist, moving)
    local p = progress()
    local key = p and (tostring(p.route) .. '#' .. tostring(p.n)) or nil
    if key ~= lastKey then -- a lap started or ended
      if rec then
        if p and p.route == rec.route and lastProg >= rec.len * 0.97 then rec.lapDone = true end
        finish(p and 'next lap' or 'lap ended')
      end
      done, nextDone, calledTo = nextDone, {}, nil
      if p and (armed == true or (armed and armed == p.route)) then
        armed = false
        rec = { level = p.level, route = p.route, n = p.n, len = p.len, closed = p.closed, calls = {}, maxProg = 0 }
        if C.notify then C.notify('Recce: recording the calls for this lap.') end
      end
      lastKey = key
    end
    lastProg = p and p.prog or 0
    if not p then return false end
    if rec then
      rec.maxProg = max(rec.maxProg, p.prog)
      return false -- recording: the coach calls as usual, and R.onCall keeps them
    end
    if C.cfg.recce == false then return false end
    local d = load(p.level, p.route)
    -- a recce of another road that got this route's id (a deleted route's id is given out again)
    if not d or (tonumber(d.len) and abs(d.len - p.len) > 0.03 * p.len) or (d.closed or false) ~= (p.closed or false) then return false end
    local whole = (d.covered or d.len) >= d.len * 0.97
    local lastS
    for i, c in ipairs(moving ~= false and d.calls or {}) do
      local ahead = c.s - p.prog
      local wrapped = d.closed and whole and ahead < -50 -- (a partial recce leaves the line to the coach)
      if wrapped then ahead = ahead + d.len end -- the next lap's first corners
      local seen = wrapped and nextDone or done
      if not seen[i] then
        if ahead <= callDist and ahead > -5 then
          seen[i] = true
          lastS = not wrapped and c.s or lastS
          if ahead >= 6 then
            C.say(c.words)
            C.announce(c.text)
          end
        end
      end
    end
    if lastS then calledTo = lastS end
    if p.prog <= (d.covered or d.len) then return true end
    -- (+30 m: the coach's own estimate of a corner's entry differs a little from the recorded one)
    return false, calledTo and calledTo - p.prog + 30 or nil
  end

  -- a call the coach just made, `dist` metres before the corner: kept while recording
  function R.onCall(dist, words, text)
    if not rec then return end
    local p = progress()
    if not p or p.route ~= rec.route then return end
    local s = p.prog + dist
    if rec.closed and s > rec.len then s = s - rec.len end
    for _, c in ipairs(rec.calls) do
      if abs(c.s - s) < 10 then return end -- called already (a repeat after a reset)
    end
    local w = {}
    for i, x in ipairs(words) do w[i] = x end
    rec.calls[#rec.calls + 1] = { s = math.floor(s * 10 + 0.5) / 10, words = w, text = text }
  end

  -- on: record the next lap that starts on `route` (any route when nil); false cancels
  function R.arm(on, route)
    armed = on ~= false and (route or true)
    if not armed and rec then rec = nil end
    return armed
  end

  function R.clear(level, route)
    local p = M.path(level, route)
    cache[p] = nil
    if FS:fileExists(p) then FS:removeFile(p) return true end
    return false
  end

  -- per route on a level: { [route] = { calls, covered, date } } for the settings panel
  function R.info(level, routes)
    local out = {}
    for _, id in ipairs(routes or {}) do
      local d = load(level, id)
      if d then out[id] = { calls = #d.calls, covered = d.covered, date = d.date } end
    end
    return out
  end

  function R.state()
    return { armed = armed ~= false, armedRoute = armed ~= true and armed or nil, recording = rec and { route = rec.route, calls = #rec.calls, prog = math.floor(rec.maxProg) } or nil }
  end

  return R
end

return M
