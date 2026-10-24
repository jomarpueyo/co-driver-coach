-- Run with main's coDriverAnalysis.lua as A: turns SRC (any session file) into a 20 Hz v1 session,
-- lets main analyse it and save it on unload (which writes the sparse, string-keyed samples).
local s = readJSON(SRC)
local out = {}
for i = 1, #s.samples, 3 do
  local r = {}
  for f = 1, 17 do r[f] = tonumber(s.samples[i][f] or s.samples[i][tostring(f)]) or 0 end
  out[#out + 1] = r
end
writeText('settings/coDriverCoach/last_session.json', jsonEncode({ date = '2026-10-18 14:48', level = s.level, model = s.model, parts = {}, samples = out }))
print('v1 load by main:', A.loadLast(), 'n', A.getResult().n)
A.onExtensionUnloaded()
local back = readJSON('settings/coDriverCoach/last_session.json')
local sparse = 0
for _, smp in ipairs(back.samples) do if smp[1] == nil then sparse = sparse + 1 end end
print('main saved', #back.samples, 'samples,', sparse, 'of them string-keyed')
