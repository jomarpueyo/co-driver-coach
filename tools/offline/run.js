// node run.js <analysis.lua> <test.lua>
// Runs the analysis extension in fengari (a Lua 5.3 VM in JS) with mocked game APIs from
// mocks.lua, then the test script with the extension as global A. Env vars MODE, OUT, SRC and ENG are
// passed to the test as Lua globals. Needs fengari@0.1.4 on NODE_PATH (see README.md).
const fs = require('fs'), path = require('path')
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari')
const L = lauxlib.luaL_newstate()
lualib.luaL_openlibs(L)
for (const k of ['MODE', 'OUT', 'SRC', 'ENG']) {
  if (process.env[k]) { lua.lua_pushstring(L, to_luastring(process.env[k])); lua.lua_setglobal(L, to_luastring(k)) }
}

function pushJS (v) {
  if (v === null || v === undefined) lua.lua_pushnil(L)
  else if (typeof v === 'boolean') lua.lua_pushboolean(L, v)
  else if (typeof v === 'number') lua.lua_pushnumber(L, v)
  else if (typeof v === 'string') lua.lua_pushstring(L, to_luastring(v))
  else if (Array.isArray(v)) {
    lua.lua_createtable(L, v.length, 0)
    for (let i = 0; i < v.length; i++) { pushJS(v[i]); lua.lua_rawseti(L, -2, i + 1) }
  } else {
    lua.lua_createtable(L, 0, 0)
    for (const k of Object.keys(v)) { pushJS(v[k]); lua.lua_setfield(L, -2, to_luastring(k)) }
  }
}
// readJSON(file) -> Lua table
lua.lua_pushcfunction(L, function (L) {
  const f = to_jsstring(lauxlib.luaL_checkstring(L, 1))
  if (!fs.existsSync(f)) { lua.lua_pushnil(L); return 1 }
  pushJS(JSON.parse(fs.readFileSync(f, 'utf8')))
  return 1
})
lua.lua_setglobal(L, to_luastring('readJSON'))
// writeText(file, s)
lua.lua_pushcfunction(L, function (L) {
  fs.writeFileSync(to_jsstring(lauxlib.luaL_checkstring(L, 1)), Buffer.from(lauxlib.luaL_checklstring(L, 2)))
  return 0
})
lua.lua_setglobal(L, to_luastring('writeText'))
// readTextJS(file) -> string or nil
lua.lua_pushcfunction(L, function (L) {
  const f = to_jsstring(lauxlib.luaL_checkstring(L, 1))
  if (!fs.existsSync(f)) { lua.lua_pushnil(L); return 1 }
  lua.lua_pushstring(L, to_luastring(fs.readFileSync(f, 'latin1'), true))
  return 1
})
lua.lua_setglobal(L, to_luastring('readTextJS'))
lua.lua_pushcfunction(L, function (L) { lua.lua_pushboolean(L, fs.existsSync(to_jsstring(lauxlib.luaL_checkstring(L, 1)))); return 1 })
lua.lua_setglobal(L, to_luastring('fileExistsJS'))
lua.lua_pushcfunction(L, function (L) { try { fs.unlinkSync(to_jsstring(lauxlib.luaL_checkstring(L, 1))) } catch (e) {} return 0 })
lua.lua_setglobal(L, to_luastring('removeFileJS'))
lua.lua_pushcfunction(L, function (L) { fs.mkdirSync(to_jsstring(lauxlib.luaL_checkstring(L, 1)), { recursive: true }); return 0 })
lua.lua_setglobal(L, to_luastring('mkdirJS'))
lua.lua_pushcfunction(L, function (L) { lua.lua_pushnumber(L, performance.now() / 1000); return 1 })
lua.lua_setglobal(L, to_luastring('nowSecs'))

function run (file, name) {
  const src = fs.readFileSync(file)
  if (lauxlib.luaL_loadbuffer(L, src, null, to_luastring('@' + name)) !== lua.LUA_OK ||
      lua.lua_pcall(L, 0, 1, 0) !== lua.LUA_OK) {
    console.log('LUA ERROR in', name, ':', to_jsstring(lua.lua_tostring(L, -1)))
    process.exit(1)
  }
}
// require() finds the extension's own modules (e.g. coDriverLaps/courses.lua) next to it
lua.lua_getglobal(L, to_luastring('package'))
lua.lua_pushstring(L, to_luastring(path.join(path.dirname(path.resolve(process.argv[2])), '?.lua').split(path.sep).join('/') + ';./?.lua'))
lua.lua_setfield(L, -2, to_luastring('path'))
lua.lua_pop(L, 1)
run(path.join(__dirname, 'mocks.lua'), 'mocks.lua')
lua.lua_setglobal(L, to_luastring('_mockret'))
run(process.argv[2], 'coDriverAnalysis.lua')
lua.lua_setglobal(L, to_luastring('A'))
run(process.argv[3], path.basename(process.argv[3]))
