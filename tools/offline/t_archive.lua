-- Run with the branch's coDriverAnalysis.lua as A, after t_make_v1.lua.
local ok = A.loadLast()
local R = A.getResult()
print('v1 file on the branch: ok', ok, 'err', R.error, 'n', R.n, 'session', R.session, 'hasReplay', R.hasReplay)
local list = A.listSessions()
print('archived', #list, list[1] and jsonEncode(list[1]))
print('loadSession by name:', A.loadSession(list[1].name), A.getResult().session)
-- 22 more sessions (different dates): the archive keeps every one (nothing is deleted automatically)
local base = readJSON('settings/coDriverCoach/last_session.json')
for k = 1, 22 do
  base.date = string.format('2026-10-%02d 10:%02d', 1 + k % 9, k)
  writeText('settings/coDriverCoach/last_session.json', jsonEncode(base))
  A.loadLast()
end
list = A.listSessions()
local files = 0
for _, e in ipairs(list) do if fileExistsJS('settings/coDriverCoach/sessions/' .. e.name .. '.json') then files = files + 1 end end
print('after 23 sessions: index', #list, 'files present', files, 'newest', list[1].name, 'oldest', list[#list].name)
print('none deleted?', #list == 23 and files == 23)
-- a too-short session is not archived
local short = { date = '2026-11-01 09:00', level = 'x', model = 'y', parts = {}, samples = {} }
for i = 1, 40 do short.samples[i] = { i * 0.05, i, 0, 0, 20, 0, 0, 1, 0, 0, 0, 0, 1, 1000, 0, 0, 20 } end
writeText('settings/coDriverCoach/last_session.json', jsonEncode(short))
A.loadLast()
print('short session archived?', #A.listSessions() ~= #list or A.listSessions()[1].name ~= list[1].name)
