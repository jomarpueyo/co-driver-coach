// node panel_stretches.js <app.js> <result.json from t_lapscope.lua OUT=>: loads the panel with a stub angular, then compares its
// lapStretches (every lap against the best one) with the Lua side's l.stretches / l.ahead
const fs = require('fs')
let ddo = null
global.angular = { module: () => ({ directive: (name, arr) => { ddo = arr[arr.length - 1](); return {} } }) }
new Function(fs.readFileSync(process.argv[2], 'utf8'))()
if (!ddo || typeof ddo.link !== 'function' || typeof ddo.template !== 'string') { console.log('FAIL: no directive'); process.exit(1) }
console.log('panel parses; template', ddo.template.length, 'chars')
const R = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'))
const L = R.laps
let fails = 0, pairs = 0
const key = x => [x.s0, x.s1, x.gain, x.rate, x.where, x.turn].join('|')
for (const l of L.list) {
  if (l.key === L.ref || !l.tAt) continue
  const r = ddo._lapStretches(L, l.key, L.ref)
  pairs++
  const a = r.lost.map(key).join('\n'), b = (l.stretches || []).map(key).join('\n')
  const c = r.won.map(key).join('\n'), d = (l.ahead || []).map(key).join('\n')
  if (a !== b || c !== d) { fails++; console.log('FAIL L' + l.n + '\nJS:\n' + a + '\n' + c + '\nLua:\n' + b + '\n' + d) }
}
// any pair works and is antisymmetric: a's losses to b are b's gains on a (same cells)
const r12 = ddo._lapStretches(L, 4, 1), r21 = ddo._lapStretches(L, 1, 4)
let own = 0
for (let c = 1; c < r12.own.length; c++) if (r12.own[c] && r12.own[c] !== 3 - r21.own[c]) own++
if (own) { fails++; console.log('FAIL owners not mirrored in', own, 'cells') }
console.log('L4 vs L1 lost:', r12.lost.slice(0, 3).map(x => x.where + ' ' + x.gain + ' s').join('; '))
console.log(pairs, 'pairs checked against Lua;', fails ? 'FAILS ' + fails : 'PASS')
