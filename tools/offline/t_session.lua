local t0 = os.clock()
local ok = A.loadLast()
local R = A.getResult() or {}
local dt = os.clock() - t0
local js = jsonEncode(R)
if OUT then writeText(OUT, js) end
print(string.format('ok=%s secs=%.2f bytes=%d n=%s trace=%s corners=%s gap=%s drive=%s ideal=%s rays=%d err=%s',
  tostring(ok), dt, #js, tostring(R.n), tostring(R.trace and #R.trace.s), tostring(R.corners and #R.corners), tostring(R.gap), tostring(R.tDrive), tostring(R.tIdeal), RAYS, tostring(R.error)))
print('limits', jsonEncode(R.limits or {}))
print('model', jsonEncode(R.model or {}))
for i, id in ipairs(R.order or {}) do
  if i > 5 then break end
  for _, c in ipairs(R.corners) do if c.id == id then print(c.id, c.loss, c.note) end end
end
