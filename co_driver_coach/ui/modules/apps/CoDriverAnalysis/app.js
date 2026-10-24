angular.module('beamng.apps')
.directive('coDriverAnalysis', [function () {
  // "Where the time is" between two laps (keys aKey and bKey) from each lap's time at the 10 m cell
  // boundaries (laps.list[].tAt), the same method as lapAnalysis in coDriverAnalysis.lua: the quicker
  // lap owns a cell, a run under 3 cells between two runs of the other lap is merged into them,
  // stretches under 0.02 s or 0.01 s per 100 m are dropped and the rest ranked by rate.
  // lost: where lap a lost to lap b (top 8); won: where it was quicker (top 3); own: each cell's
  // owner after the merge (1-based, 1 = lap b, 2 = lap a, 0 = no data).
  const STRETCH = { flicker: 3, minGain: 0.02, minRate: 0.01, top: 8, ahead: 3 }
  function placeAt (turns, s) { // "T6 exit", "40 m before T7"
    let prev = null, nxt = null
    for (const tn of turns) {
      if (s >= tn.a && s <= tn.b) return 'T' + tn.id + (s < tn.s ? ' entry' : ' exit')
      if (tn.b < s && (!prev || tn.b > prev.b)) prev = tn
      if (tn.a > s && (!nxt || tn.a < nxt.a)) nxt = tn
    }
    const dp = prev ? s - prev.b : null, dn = nxt ? nxt.a - s : null
    if (dp != null && (dn == null || dp <= dn)) return dp < 15 ? 'T' + prev.id + ' exit' : Math.floor(dp / 10 + 0.5) * 10 + ' m after T' + prev.id
    if (dn != null) return dn < 15 ? 'T' + nxt.id + ' entry' : Math.floor(dn / 10 + 0.5) * 10 + ' m before T' + nxt.id
    return (s / 1000).toFixed(2) + ' km'
  }
  function lapStretches (laps, aKey, bKey) {
    const list = Array.isArray(laps && laps.list) ? laps.list : []
    const turns = Array.isArray(laps && laps.turns) ? laps.turns : []
    const A = list[aKey - 1], B = list[bKey - 1], n = laps && laps.cells, cm = laps && laps.cellM
    if (!A || !B || !Array.isArray(A.tAt) || !Array.isArray(B.tAt) || !n || !cm) return null
    const cellT = (l, c) => { const x = l.tAt[c - 1], y = l.tAt[c]; return x >= 0 && y >= 0 ? y - x : null }
    const own = new Int8Array(n + 1)
    for (let c = 1; c <= n; c++) {
      const a = cellT(A, c), b = cellT(B, c)
      if (a != null && b != null) own[c] = a - b > 0 || (a === b && bKey < aKey) ? 1 : 2 // a tie: the lower key, as in the Lua
    }
    const runs = []
    for (let c = 1; c <= n; c++) {
      const o = own[c], r = runs[runs.length - 1]
      if (o && r && r.o === o && r.c1 === c - 1) r.c1 = c
      else if (o) runs.push({ o, c0: c, c1: c })
    }
    for (let i = 1; i < runs.length - 1;) {
      const p = runs[i - 1], r = runs[i], q = runs[i + 1]
      if (r.c1 - r.c0 + 1 < STRETCH.flicker && p.o === q.o && p.c1 === r.c0 - 1 && r.c1 === q.c0 - 1) { p.c1 = q.c1; runs.splice(i, 2) } else i++
    }
    const lost = [], won = []
    for (const r of runs) {
      let g = 0
      for (let c = r.c0; c <= r.c1; c++) {
        own[c] = r.o
        const d = cellT(A, c) - cellT(B, c)
        g += r.o === 1 ? d : -d
      }
      const s0 = (r.c0 - 1) * cm, s1 = r.c1 * cm, rate = g / (s1 - s0) * 100
      if (g < STRETCH.minGain || rate < STRETCH.minRate) continue
      let near = null, nd = Infinity
      for (const tn of turns) {
        const d = Math.max(0, tn.a - s1, s0 - tn.b)
        if (d < nd) { near = tn.id; nd = d }
      }
      const a = placeAt(turns, s0), b = placeAt(turns, s1), ta = a.match(/^(T\d+) e/), tb = b.match(/^(T\d+) e/)
      const x = { s0: Math.round(s0), s1: Math.round(s1), turn: near, gain: Math.round(g * 100) / 100, rate: Math.round(rate * 1000) / 1000,
        by: r.o === 1 ? bKey : aKey, where: a === b ? a : (ta && tb && ta[1] === tb[1] ? ta[1] : a + ' to ' + b) }
      if (r.o === 1) lost.push(x); else won.push(x)
    }
    const byRate = (x, y) => (y.rate - x.rate) || (x.s0 - y.s0)
    return { lost: lost.sort(byRate).slice(0, STRETCH.top), won: won.sort(byRate).slice(0, STRETCH.ahead), own }
  }
  return {
    _lapStretches: lapStretches, // for the offline check against the Lua side
    template: `
<div class="cda" ng-class="{replay: st.mode === 'replay'}">
  <style>
    .cda { position:fixed; inset:0; pointer-events:none; font-family:'Roboto', sans-serif; color:#e8e8e8;
           font-size:calc(12px * var(--ui-scale, 1)); }
    .cda .card { position:absolute; left:3%; right:3%; top:4%; bottom:3%; pointer-events:auto; display:flex; flex-direction:column;
                 background:rgba(13,15,18,0.94); border-radius:0.8em; padding:0.9em 1.1em; box-sizing:border-box; gap:0.6em; }
    .cda.replay .card { top:auto; height:36%; bottom:2%; left:2%; right:2%; background:rgba(13,15,18,0.82); }
    .cda .hdr { display:flex; align-items:center; gap:1.2em; flex:0 0 auto; }
    .cda .ttl { font-size:0.95em; font-weight:700; letter-spacing:0.15em; color:#9aa3ad; }
    .cda .sum { color:#c8ced6; }
    .cda .sum b { color:#fff; }
    .cda .gap { color:#ffb870; font-weight:700; }
    .cda .sub { color:#7d868f; font-size:0.9em; }
    .cda .btn { cursor:pointer; padding:0.3em 0.8em; border-radius:0.35em; background:#2b3038; color:#d6dbe1; font-size:0.9em; white-space:nowrap; user-select:none; }
    .cda .btn:hover { background:#3a414c; color:#fff; }
    .cda .btn.on { background:#4b6fae; color:#fff; }
    .cda .btn.prim { background:#3a7bd5; color:#fff; }
    .cda .grow { flex:1 1 auto; }
    .cda .main { display:flex; gap:0.9em; flex:1 1 auto; min-height:0; }
    .cda .eng { display:flex; align-items:center; gap:0.6em; flex:0 0 auto; }
    .cda .mic { cursor:pointer; user-select:none; padding:0.35em 0.9em; border-radius:1em; background:#2b3038; color:#e8e8e8; font-weight:600; white-space:nowrap; }
    .cda .mic:hover { background:#3a414c; }
    .cda .mic.on { background:#c0392b; color:#fff; }
    .cda .mic.off { opacity:0.45; }
    .cda .q { flex:1 1 auto; min-width:0; background:#1b1f25; border:1px solid #2f353e; border-radius:0.4em; color:#e8e8e8; padding:0.35em 0.6em; font-size:1em; font-family:inherit; outline:none; }
    .cda .q:focus { border-color:#3a7bd5; }
    .cda .eset { display:flex; align-items:center; gap:0.6em; flex:0 0 auto; flex-wrap:wrap; }
    .cda .ehelp { color:#7d868f; font-size:0.85em; }
    .cda .ehelp b { color:#c8ced6; font-weight:600; }
    .cda .estat { color:#7d868f; font-size:0.85em; white-space:nowrap; }
    .cda .estat.ok { color:#8fd694; }
    .cda .ans { flex:0 0 auto; background:rgba(58,123,213,0.12); border-left:0.25em solid #3a7bd5; border-radius:0.5em; padding:0.45em 0.8em; max-height:6.5em; overflow-y:auto; }
    .cda .ans .aq { color:#9aa3ad; font-style:italic; margin-right:0.5em; }
    .cda .ans .aa { color:#fff; }
    .cda .ans .src { color:#5d666f; font-size:0.8em; margin-left:0.5em; }
    .cda .mapbox { flex:1 1 auto; position:relative; background:#171a1f; border-radius:0.5em; overflow:hidden; }
    .cda .mapbox canvas { position:absolute; inset:0; width:100%; height:100%; }
    .cda .maplegend { position:absolute; left:0.6em; bottom:0.5em; font-size:0.85em; color:#9aa3ad; pointer-events:none; }
    .cda .maplegend i { display:inline-block; width:1.4em; height:0.25em; vertical-align:middle; margin:0 0.3em 0 0.8em; border-radius:0.2em; }
    .cda .mapbtns { position:absolute; right:0.5em; top:0.5em; display:flex; gap:0.4em; }
    .cda .side { flex:0 0 34%; display:flex; flex-direction:column; gap:0.5em; min-width:0; min-height:0; }
    .cda .good { background:rgba(60,150,90,0.16); border-left:0.25em solid #6fe08a; border-radius:0.5em; padding:0.5em 0.8em; flex:0 0 auto; }
    .cda .good .tt { font-size:0.85em; font-weight:700; letter-spacing:0.1em; color:#a8e6b4; margin-bottom:0.2em; }
    .cda .good div.tip { margin:0.2em 0; }
    .cda .good .ref { cursor:pointer; color:#a8e6b4; text-decoration:underline; margin-left:0.3em; font-size:0.9em; }
    .cda .gd { color:#8fd694; font-size:0.95em; margin-top:0.12em; }
    .cda .lhdr { display:flex; align-items:center; gap:0.4em; flex:0 0 auto; }
    .cda .lhdr .tt { font-size:0.85em; font-weight:700; letter-spacing:0.1em; color:#9aa3ad; }
    .cda .setbox { flex:0 0 auto; display:flex; flex-direction:column; gap:0.45em; background:#171a1f; border-radius:0.5em; padding:0.6em 0.8em; }
    .cda .maplegend .dots b { display:inline-block; width:0.75em; height:0.75em; border-radius:50%; margin:0 0.3em 0 0.9em; vertical-align:middle; }
    .cda .maplegend .di { background:#5a606b; } .cda .maplegend .dg { background:#3f9a5a; } .cda .maplegend .dy { background:#b8912e; } .cda .maplegend .dr { background:#c4554a; }
    .cda .tips { background:rgba(90,59,140,0.22); border-left:0.25em solid #8e6bd1; border-radius:0.5em; padding:0.5em 0.8em; flex:0 0 auto; }
    .cda .tips .tt { font-size:0.85em; font-weight:700; letter-spacing:0.1em; color:#c9b6f0; margin-bottom:0.2em; }
    .cda .tips div.tip { margin:0.25em 0; }
    .cda .refs { color:#9aa3ad; font-size:0.9em; }
    .cda .tips .ref { cursor:pointer; color:#c9b6f0; text-decoration:underline; margin-left:0.3em; }
    .cda .list { flex:1 1 auto; overflow-y:auto; min-height:0; }
    .cda .row { padding:0.45em 0.6em; border-radius:0.4em; cursor:pointer; display:flex; gap:0.7em; align-items:flex-start; }
    .cda .row:hover { background:rgba(255,255,255,0.05); }
    .cda .row.sel { background:rgba(58,123,213,0.22); }
    .cda .row .num { font-weight:800; font-size:1.1em; min-width:1.7em; color:#fff; text-align:center; border-radius:0.4em; padding:0.1em 0.2em; }
    .cda .row .num.ok { background:#2f6e43; } .cda .row .num.mid { background:#7d6424; } .cda .row .num.bad { background:#8a3a32; }
    .cda .row .num.inc { background:#4a4f58; }
    .cda .row .ls.inc { color:#9aa3ad; font-weight:600; }
    .cda .row .nt.inc { color:#e0a96d; }
    .cda .row .rb { flex:1 1 auto; min-width:0; }
    .cda .row .nm { color:#c8ced6; font-weight:700; }
    .cda .row .nt { color:#aab2bb; font-size:0.95em; margin-top:0.15em; line-height:1.35; }
    .cda .row .ls { margin-left:auto; font-weight:700; white-space:nowrap; }
    .cda .row .ls.bad { color:#ff7b6b; } .cda .row .ls.mid { color:#ffd166; } .cda .row .ls.ok { color:#8fd694; }
    .cda .row .rp { margin-left:0.6em; }
    .cda .charts { flex:0 0 34%; position:relative; min-height:0; background:#14171b; border-radius:0.5em; }
    .cda.replay .charts { flex:1 1 auto; }
    .cda .charts canvas { position:absolute; inset:0; width:100%; height:100%; }
    .cda .foot { flex:0 0 auto; display:flex; align-items:center; gap:0.8em; color:#9aa3ad; font-size:0.92em; }
    .cda .foot .ro b { color:#fff; font-weight:600; }
    .cda .foot .ro .y { color:#ffa64d; } .cda .foot .ro .g { color:#6fe08a; }
    .cda .msg { color:#c8ced6; padding:2em; text-align:center; }
    .cda .rnote { color:#e8e8e8; }
    .cda .rnote .nm { font-weight:800; margin-right:0.5em; }
    .cda .hint { color:#5d666f; font-size:0.85em; }
    .cda .sess { flex:0 0 auto; max-height:12em; overflow-y:auto; background:#171a1f; border-radius:0.5em; padding:0.3em 0.4em; }
    .cda .srow { display:flex; align-items:center; gap:1.2em; padding:0.3em 0.5em; border-radius:0.35em; cursor:pointer; }
    .cda .srow:hover { background:rgba(255,255,255,0.05); }
    .cda .srow.cur { background:rgba(58,123,213,0.22); }
    .cda .srow .sd { color:#fff; font-weight:600; min-width:9em; }
    .cda .srow .sl { color:#c8ced6; min-width:9em; }
    .cda .srow .sm { color:#9aa3ad; }
    .cda .setbox { flex:1 1 auto; min-height:0; overflow-y:auto; }
    .cda .stt { font-size:0.85em; font-weight:700; letter-spacing:0.1em; color:#9aa3ad; margin-top:0.3em; }
    .cda .route { display:flex; align-items:center; gap:0.6em; padding:0.15em 0; }
    /* settings: cards in a grid, label / control rows, help under its row */
    .cda .setbox.setbox { display:block; padding:0.7em; }
    .cda .sgrid { display:grid; grid-template-columns:repeat(auto-fill, minmax(30em, 1fr)); gap:0.7em; }
    .cda .scard { background:#1d2127; border:1px solid #272c34; border-radius:0.5em; padding:0.65em 0.85em; display:flex; flex-direction:column; gap:0.5em; min-width:0; }
    .cda .scard.wide { grid-column:1 / -1; }
    .cda .scard h4 { margin:0; font-size:0.8em; font-weight:700; letter-spacing:0.12em; text-transform:uppercase; color:#9aa3ad; }
    .cda .h4sub { font-weight:400; letter-spacing:0; text-transform:none; color:#6f7881; margin-left:0.5em; }
    .cda .srow { display:grid; grid-template-columns:8.5em minmax(0, 1fr); gap:0.7em; align-items:start; }
    .cda .srow > label { color:#aab2bb; font-size:0.88em; padding-top:0.3em; }
    .cda .seg { display:inline-flex; flex-wrap:wrap; gap:1px; background:#14171b; border-radius:0.4em; padding:1px; }
    .cda .seg .btn { border-radius:0.3em; }
    .cda .srow > .seg, .cda .srow > .tgl { justify-self:start; }
    .cda .tgl { display:flex; flex-wrap:wrap; gap:0.35em; align-items:center; }
    .cda .shelp { color:#7d868f; font-size:0.82em; line-height:1.4; margin-top:0.3em; }
    .cda .shelp b { color:#c8ced6; font-weight:600; }
    .cda .sval { color:#d6dbe1; font-size:0.9em; padding-top:0.3em; }
    .cda .ssub { display:flex; align-items:center; gap:0.6em; margin-top:0.4em; padding-top:0.5em; border-top:1px solid #272c34; color:#c8ced6; font-size:0.88em; font-weight:600; }
    .cda .rlist { display:flex; flex-direction:column; }
    .cda .rrow { display:grid; grid-template-columns:minmax(16em, 28em) auto; justify-content:start; align-items:center; gap:0.8em; padding:0.4em 0.2em; border-bottom:1px solid #22262d; }
    .cda .rrow:last-child { border-bottom:none; }
    .cda .rname { flex:1 1 auto; min-width:0; }
    .cda .rname b { color:#e3e7ec; font-weight:600; }
    .cda .rsub { color:#7d868f; font-size:0.82em; }
    .cda .racts { display:flex; flex-wrap:wrap; gap:0.35em; }
    .cda .btn.sm { padding:0.22em 0.65em; font-size:0.82em; }
    .cda .btn.warn { background:#6b2f2a; color:#fff; }
    .cda .lapbar { display:flex; align-items:center; gap:0.4em; flex-wrap:wrap; flex:0 0 auto; }
    .cda .lapbar .tt, .cda .laptab .tt { font-size:0.85em; font-weight:700; letter-spacing:0.1em; color:#9aa3ad; margin-right:0.3em; }
    .cda .btn.inv { color:#8a929b; font-style:italic; }
    .cda .star { color:#ffd166; }
    .cda .laptab { flex:0 0 auto; max-height:14em; overflow-y:auto; background:#171a1f; border-radius:0.5em; padding:0.45em 0.7em; }
    .cda .laptab table { border-collapse:collapse; width:100%; margin-top:0.2em; }
    .cda .laptab th { color:#7d868f; font-weight:600; text-align:left; padding:0.1em 0.45em; font-size:0.9em; }
    .cda .laptab td { padding:0.15em 0.45em; white-space:nowrap; }
    .cda .laptab tr.lr { cursor:pointer; }
    .cda .laptab tr.lr:hover td { background:rgba(255,255,255,0.05); }
    .cda .laptab tr.inv td { color:#7d868f; }
    .cda .laptab td.pb { color:#c792ea; font-weight:700; }
    .cda .laptab tr.cur td { background:rgba(58,123,213,0.22); }
    .cda .row .tn { color:#9ec3ff; font-weight:700; }
    .cda .row .vb { color:#9aa3ad; font-size:0.9em; }
    .cda .where { flex:0 0 auto; max-height:11em; overflow-y:auto; background:rgba(255,166,77,0.10); border-left:0.25em solid #ffa64d; border-radius:0.5em; padding:0.45em 0.7em; }
    .cda .where .tt { font-size:0.85em; font-weight:700; letter-spacing:0.1em; color:#ffc58f; margin-bottom:0.15em; }
    .cda .where .wr { display:flex; align-items:baseline; gap:0.5em; padding:0.12em 0.35em; border-radius:0.35em; cursor:pointer; white-space:nowrap; }
    .cda .where .wr:hover { background:rgba(255,255,255,0.05); }
    .cda .where .wr.sel { background:rgba(58,123,213,0.22); }
    .cda .where .wl { color:#e8e8e8; overflow:hidden; text-overflow:ellipsis; min-width:0; }
    .cda .where .wg { margin-left:auto; font-weight:700; color:#ff7b6b; }
    .cda .where .wr.won .wg { color:#8fd694; }
  </style>

  <div class="card" ng-show="st.open">
    <div class="hdr">
      <span class="ttl">DRIVE ANALYSIS</span>
      <span class="sum" ng-if="d.n && st.mode !== 'replay' && curLap()">
        Lap {{ curLap().n }} <b>{{ lapTime(curLap().time) }}</b> ·
        <span ng-if="curLap().valid">{{ curLap().delta > 0.005 ? '+' + curLap().delta.toFixed(2) + ' s to your best lap' : 'your best lap' }}</span>
        <span class="gap" ng-if="!curLap().valid">not counted: {{ curLap().reason || 'invalid' }}</span>
        <span ng-if="cmpSel != null && cmpLapTime() != null"> · {{ gapText(curLap().time - cmpLapTime()) }} s against {{ cmpSel === 'ever' ? 'your best ever' : 'lap ' + lapN(cmpSel) }}</span>
        <span class="sub" ng-if="topText(curLap())"> · lost most at {{ topText(curLap()) }} (against your best pass of each turn)</span>
      </span>
      <span class="sum" ng-if="d.n && st.mode !== 'replay' && !curLap()">
        You <b>{{ clock(d.tDrive) }}</b> · better line <b>{{ clock(d.tIdeal) }}</b> · <span class="gap">{{ d.gap.toFixed(1) }} s</span> to find<span ng-if="d.incidents && d.gapClean > 0.05"> ({{ d.gapClean.toFixed(1) }} s without {{ d.incidents }} incident{{ d.incidents > 1 ? 's' : '' }})</span><span ng-if="d.incidents && !(d.gapClean > 0.05)"> ({{ d.incidents }} incident{{ d.incidents > 1 ? 's' : '' }} cost more than that: everywhere else you matched the better line)</span>
        <span class="sub" ng-if="d.level"> · {{ d.level }}{{ d.car ? ', ' + d.car : '' }}</span>
      </span>
      <span class="rnote" ng-if="st.mode === 'replay'">
        <span class="nm" ng-if="cornerById(st.replay.corner)">Corner {{ st.replay.corner }} · {{ cornerById(st.replay.corner).dir }}<span ng-if="cornerById(st.replay.corner).loss > 0"> · −{{ cornerById(st.replay.corner).loss.toFixed(2) }} s</span></span>
        <span class="gd" ng-if="list(cornerById(st.replay.corner).good).length">✓ {{ list(cornerById(st.replay.corner).good)[0] }} · </span>
        <span>{{ st.replay.msg || (cornerById(st.replay.corner) ? cornerById(st.replay.corner).note : 'Replay') }}</span>
      </span>
      <span class="grow"></span>
      <span ng-if="st.mode === 'replay'" style="display:flex; gap:0.4em">
        <span class="btn" ng-click="stepCorner(-1)" title="previous turn (or the start of this one)">◀ turn</span>
        <span class="btn prim" ng-click="pauseReplay(!st.replay.paused)">{{ st.replay.paused ? '▶ play' : '❚❚ pause' }}</span>
        <span class="btn" ng-class="{on: st.replay.speed === 0.25}" ng-click="speed(0.25)">¼×</span>
        <span class="btn" ng-class="{on: st.replay.speed === 0.5}" ng-click="speed(0.5)">½×</span>
        <span class="btn" ng-class="{on: st.replay.speed === 1}" ng-click="speed(1)">1×</span>
        <span class="btn" ng-click="stepCorner(1)" title="next turn">turn ▶</span>
        <span class="btn" ng-click="exitReplay()">back to analysis</span>
      </span>
      <span class="btn prim" ng-if="d.n && d.hasReplay && st.mode !== 'replay' && !(curLap() && !selId)" ng-click="replayDrive()" title="play the drive from the selected turn, turn by turn">▶ replay{{ selId ? ' from ' + cornerLabel(cornerById(selId)) : '' }}</span>
      <span class="btn prim" ng-if="d.n && st.mode !== 'replay' && curLap() && !selId && curLap().hasReplay" ng-click="replayLap()" title="play this lap from the start line">▶ replay lap {{ curLap().n }}</span>
      <span class="btn" ng-if="d.n && st.mode !== 'replay'" ng-class="{on: showCharts}" ng-click="toggleCharts()">telemetry</span>
      <span class="btn" ng-if="st.mode !== 'replay'" ng-class="{on: sessOpen}" ng-click="toggleSessions()">sessions</span>
      <span class="btn" ng-if="st.mode !== 'replay'" ng-class="{on: setOpen}" ng-click="toggleSettings()">settings</span>
      <span class="btn" ng-click="close()">close</span>
    </div>

    <div class="lapbar" ng-if="lapList().length && d.n && st.mode !== 'replay'">
      <span class="tt">LAPS</span>
      <span class="btn" ng-class="{on: lapSel == null}" ng-click="selectLap(null)" title="the whole drive">all</span>
      <span class="btn" ng-repeat="l in lapList()" ng-class="{on: lapSel === l.key, inv: !l.valid}" ng-click="selectLap(l.key)" title="{{ l.valid ? 'lap ' + l.n : 'not counted: ' + (l.reason || 'invalid') }}">L{{ l.n }} {{ lapTime(l.time) }}<span class="star" ng-if="d.laps.ref === l.key"> ★</span></span>
      <span class="grow"></span>
      <span class="sub">{{ lapSummary() }}</span>
    </div>
    <div class="lapbar" ng-if="curLap() && curLap().delta != null && d.n && st.mode !== 'replay'">
      <span class="tt">COMPARE L{{ curLap().n }} WITH</span>
      <span class="btn" ng-repeat="l in lapList()" ng-if="l.key !== lapSel && l.delta != null" ng-class="{on: cmpKey() === l.key, inv: !l.valid}" ng-click="setCompare(l.key)">L{{ l.n }} {{ lapTime(l.time) }}<span class="star" ng-if="d.laps.ref === l.key"> ★</span></span>
      <span class="btn" ng-if="everOk()" ng-class="{on: cmpKey() === 'ever'}" ng-click="setCompare('ever')" title="your best lap on this route{{ d.laps.bestEver.car ? ' (' + d.laps.bestEver.car + ')' : '' }}, {{ d.laps.bestEver.date }}">best ever {{ lapTime(d.laps.bestEver.time) }}</span>
      <span class="sub" ng-if="cmpKey() !== lapSel">· map: <b style="color:#ffa64d">L{{ curLap().n }}</b> and <b style="color:#58b4ff">{{ cmpLabel() }}</b> · charts: the gap and both speeds at the same place on the road</span>
      <span class="sub" ng-if="cmpKey() === lapSel">· this is your best lap{{ everSame() ? ', and your best ever on this route' : '' }}: pick another lap{{ everOk() ? ' or your best ever' : '' }} to compare it with</span>
    </div>

    <div class="sess" ng-show="sessOpen && st.mode !== 'replay'">
      <div class="ehelp" ng-if="!sessions.length">No saved sessions yet. Drives of a minute or 500 m and more are kept here.</div>
      <div class="srow" ng-repeat="x in sessions" ng-class="{cur: x.name === d.session}" ng-click="openSession(x.name)">
        <span class="sd">{{ x.date }}</span><span class="sl">{{ x.level }}</span><span class="sl">{{ x.model }}</span>
        <span class="sm">{{ x.km }} km · {{ dur(x.secs) }}<span ng-if="x.laps"> · {{ x.laps }} {{ x.laps == 1 ? 'lap' : 'laps' }}<span ng-if="x.bestLap">, best {{ lapTime(x.bestLap) }}</span></span></span>
        <span class="sm" ng-if="x.fmt < 2">20 Hz (older version)</span>
        <span class="grow"></span>
        <span class="btn">{{ x.name === d.session ? 'open now' : 'open' }}</span>
      </div>
    </div>

    <div class="setbox" ng-show="setOpen && st.mode !== 'replay'">
      <div class="sgrid">
        <section class="scard" ng-if="cs.coach">
          <h4>Co-driver</h4>
          <div class="srow"><label>Call corners ahead</label>
            <div class="seg"><span class="btn" ng-repeat="x in [3.5, 4.5, 5.5, 6.5]" ng-class="{on: near(cs.coach.cfg.callAheadSec, x)}" ng-click="coachOpt('callAheadSec', x)">{{ x }} s</span></div></div>
          <div class="srow"><label>Grades</label>
            <div class="seg"><span class="btn" ng-class="{on: cs.coach.cfg.style === 'numbers'}" ng-click="coachOpt('style', 'numbers')">6–1 numbers</span><span class="btn" ng-class="{on: cs.coach.cfg.style === 'words'}" ng-click="coachOpt('style', 'words')">words</span></div></div>
          <div class="srow"><label>Surface</label>
            <div class="seg"><span class="btn" ng-repeat="x in ['tarmac', 'gravel', 'snow']" ng-class="{on: cs.coach.cfg.surface === x}" ng-click="coachCmd('setSurface(' + q(x) + ')')">{{ x }}</span></div></div>
          <div class="srow"><label>Also</label>
            <div class="tgl"><span class="btn" ng-repeat="t in toggles.codriver" ng-class="{on: cs.coach.cfg[t.k]}" ng-click="coachOpt(t.k, !cs.coach.cfg[t.k])" title="{{ t.tip }}">{{ t.label }}</span></div></div>
        </section>

        <section class="scard" ng-if="cs.coach">
          <h4>Voice</h4>
          <div class="srow"><label>Voice</label>
            <div class="seg"><span class="btn" ng-class="{on: cs.coach.cfg.voice}" ng-click="coachCmd('toggleVoice()')">{{ cs.coach.cfg.voice ? 'on' : 'off' }}</span></div></div>
          <div class="srow"><label>Voicepack</label>
            <div class="tgl"><span class="btn" ng-repeat="v in list(cs.coach.voicepacks)" ng-class="{on: cs.coach.cfg.voicepack === v}" ng-click="coachCmd('setVoicepack(' + q(v) + ')')">{{ v }}</span></div></div>
          <div class="srow"><label>Output</label>
            <div class="seg"><span class="btn" ng-class="{on: cs.coach.cfg.voiceOutput === 'plain'}" ng-click="coachOpt('voiceOutput', 'plain')" title="plays the clips directly">plain</span><span class="btn" ng-class="{on: cs.coach.cfg.voiceOutput === 'intercom'}" ng-click="coachOpt('voiceOutput', 'intercom')" title="the game's rally intercom channel">intercom</span></div></div>
          <div class="srow"><label>Volume</label>
            <div class="seg"><span class="btn" ng-repeat="x in [1, 1.5, 2, 2.5, 3]" ng-class="{on: near(cs.coach.cfg.voiceVolume, x)}" ng-click="coachOpt('voiceVolume', x)">{{ x }}×</span></div></div>
          <div class="srow"><label>Also</label>
            <div class="tgl"><span class="btn" ng-repeat="t in toggles.voice" ng-class="{on: cs.coach.cfg[t.k]}" ng-click="coachOpt(t.k, !cs.coach.cfg[t.k])" title="{{ t.tip }}">{{ t.label }}</span></div></div>
        </section>

        <section class="scard" ng-if="cs.coach">
          <h4>Driving aids</h4>
          <div class="srow"><label>Braking aid</label>
            <div class="seg"><span class="btn" ng-repeat="x in ['off', 'bar', 'zone']" ng-class="{on: cs.coach.cfg.brakeAid === x}" ng-click="coachOpt('brakeAid', x)">{{ {off: 'off', bar: 'bar on the strip', zone: 'bar + line across the road'}[x] }}</span></div></div>
          <div class="srow"><label>Also</label>
            <div class="tgl"><span class="btn" ng-repeat="t in toggles.aids" ng-class="{on: cs.coach.cfg[t.k]}" ng-click="coachOpt(t.k, !cs.coach.cfg[t.k])" title="{{ t.tip }}">{{ t.label }}</span></div></div>
          <div class="srow" ng-if="cs.coach.grip"><label>Grip targets</label>
            <div><div class="sval">{{ cs.coach.grip.lat.toFixed(2) }} g cornering · {{ cs.coach.grip.brake.toFixed(2) }} g braking</div>
              <div class="shelp">{{ gripNote() }}</div>
              <span class="btn sm" ng-class="{warn: confirmKey === 'grip'}" ng-if="cs.coach.grip.car" ng-click="confirmDo('grip', 'if coDriverCoach then coDriverCoach.resetLearnedGrip() end')">{{ confirmKey === 'grip' ? 'click again to forget' : 'forget learned grip for this car' }}</span></div></div>
        </section>

        <section class="scard">
          <h4>Race engineer</h4>
          <div class="estat" ng-class="{ok: eng.online}">{{ engStatus() }}</div>
          <div class="srow"><label>Speaks</label>
            <div class="tgl"><span class="btn" ng-class="{on: eng.speak}" ng-click="engOpt('speak', !eng.speak)">in the analysis</span><span class="btn" ng-class="{on: eng.speakDrive}" ng-click="engOpt('speakDrive', !eng.speakDrive)">while driving</span><span class="btn" ng-class="{on: eng.ownVoice}" ng-click="engOpt('ownVoice', !eng.ownVoice)" title="a short engineer line whose every word is in your co-driver voicepack (nice save, brake hard, new best...) is said in that voice instead of Kokoro">your voice for short lines</span></div></div>
          <div class="srow"><label>Calls</label>
            <div class="tgl"><span class="btn" ng-class="{on: eng.alerts}" ng-click="engOpt('alerts', !eng.alerts)">car condition alerts</span><span class="btn" ng-class="{on: eng.lapCalls}" ng-click="engOpt('lapCalls', !eng.lapCalls)" title="the engineer says your lap time and the gap to your best as you cross the line">spoken lap times</span></div></div>
          <div class="shelp">API key: one line in <b>tools\\.anthropic_key</b>, then restart engineer.bat. Talk hotkey: Controls → Bindings → Gameplay → "talk to engineer (hold)".</div>
        </section>

        <section class="scard wide" ng-if="cs.laps">
          <h4>Lap timing <span class="h4sub">{{ cs.laps.level }}</span></h4>
          <div class="srow"><label>Find routes</label>
            <div><div class="seg"><span class="btn" ng-class="{on: cs.laps.discovery === 'auto'}" ng-click="lapsOpt('discovery', 'auto')" title="a loop driven twice, or a run repeated after a reset, becomes a timed route">by themselves</span><span class="btn" ng-class="{on: cs.laps.discovery === 'off'}" ng-click="lapsOpt('discovery', 'off')" title="only routes already saved, and start/finish set with the hotkeys">off</span></div>
              <div class="shelp">Or set a start and finish anywhere with the hotkeys (Controls → Bindings → Gameplay → "Co-Driver Coach: lap timing").</div></div></div>
          <div class="srow"><label>Ghost</label>
            <div><div class="seg"><span class="btn" ng-repeat="x in ['off', 'marker', 'line']" ng-class="{on: (cs.laps.ghost || 'off') === x}" ng-click="lapsOpt('ghost', x)">{{ {off: 'off', marker: 'marker', line: 'marker + its line'}[x] }}</span></div>
              <div class="shelp">While you time a lap, a blue marker shows where your best lap on that route was at the same lap time.</div></div></div>

          <div class="ssub">Your routes</div>
          <div class="shelp" ng-if="!list(cs.laps.routes).length">None on this map yet: drive a loop twice, or set a start and finish with the hotkeys.</div>
          <div class="rlist" ng-if="list(cs.laps.routes).length">
            <div class="rrow" ng-repeat="r in list(cs.laps.routes)">
              <div class="rname"><b>{{ r.id }}</b> <span class="rsub">{{ r.closed ? 'loop' : 'point to point' }} · {{ (r.len / 1000).toFixed(2) }} km<span ng-if="r.away != null"> · {{ awayText(r.away) }}</span></span>
                <div class="rsub">{{ r.laps }} {{ r.closed ? 'laps' : 'runs' }}<span ng-if="r.best"> · best {{ lapTime(r.best) }}</span> · {{ r.source }}, {{ r.created }}<span ng-if="recceOf(r.id)"> · recce: {{ recceOf(r.id).calls }} calls</span></div></div>
              <div class="racts">
                <span class="btn sm" ng-class="{on: cs.laps.guided === r.id}" ng-click="guide(cs.laps.guided === r.id ? null : r.id)" title="ground markers lead you to its start line">{{ cs.laps.guided === r.id ? 'guiding: stop' : 'guide me' }}</span>
                <span class="btn sm" ng-click="takeTo(r.id)" title="puts your car about 40 m before its start line, facing it">take me there</span>
                <span class="btn sm" ng-if="!recceOf(r.id)" ng-class="{on: recceArmed(r.id)}" ng-click="recceArm(!recceArmed(r.id), r.id)" title="your next timed lap records the co-driver's calls on this route; later laps get exactly those calls at the same places">{{ recceArmed(r.id) ? 'recce armed: cancel' : 'recce next lap' }}</span>
                <span class="btn sm" ng-if="recceOf(r.id)" ng-class="{warn: confirmKey === 'recce' + r.id}" ng-click="confirmDo('recce' + r.id, 'if coDriverCoach then coDriverCoach.recceClear(nil, ' + q(r.id) + ') end')" title="recce of {{ recceOf(r.id).date }}, {{ recceOf(r.id).covered }} m of the route">{{ confirmKey === 'recce' + r.id ? 'click again' : 'clear recce' }}</span>
                <span class="btn sm" ng-class="{warn: confirmKey === 'laps' + r.id}" ng-click="confirmDo('laps' + r.id, 'if coDriverLaps then coDriverLaps.clearLaps(' + q(r.id) + ') end')">{{ confirmKey === 'laps' + r.id ? 'click again' : 'clear laps' }}</span>
                <span class="btn sm" ng-class="{warn: confirmKey === 'route' + r.id}" ng-click="confirmDo('route' + r.id, 'if coDriverLaps then coDriverLaps.clearRoute(' + q(r.id) + ') end')">{{ confirmKey === 'route' + r.id ? 'click again' : 'delete' }}</span>
              </div>
            </div>
          </div>
          <div class="shelp" ng-if="list(cs.laps.routes).length">Recce: arm it, drive one lap, and the co-driver's calls on it are kept; later laps get exactly those calls at the same places. <span ng-if="cs.laps.recceState.recording">Recording now: {{ cs.laps.recceState.recording.calls }} calls so far.</span></div>

          <div ng-if="list(cs.laps.courses).length">
            <div class="ssub">Official courses <span class="h4sub">{{ list(cs.laps.courses).length }} on this map · {{ coursesOn() }} timed</span>
              <span class="btn sm" ng-class="{on: showCourses}" ng-click="showCourses = !showCourses">{{ showCourses ? 'hide the list' : 'show all' }}</span></div>
            <div class="shelp" ng-if="!showCourses && !coursesOn()">Turn a course on, then drive through its start line. "guide me" shows the way there; "take me there" puts you just before it.</div>
            <div class="rlist">
              <div class="rrow" ng-repeat="c in courseList()" ng-if="showCourses || c.enabled">
                <div class="rname"><b>{{ c.name }}</b> <span class="rsub">{{ c.closed ? 'circuit' : 'point to point' }} · {{ (c.length / 1000).toFixed(2) }} km<span ng-if="c.away != null"> · {{ awayText(c.away) }}</span></span>
                  <div class="rsub" ng-if="c.laps || c.best || recceOf(c.id)"><span ng-if="c.laps">{{ c.laps }} {{ c.closed ? 'laps' : 'runs' }}</span><span ng-if="c.best"> · best {{ lapTime(c.best) }}</span><span ng-if="recceOf(c.id)"> · recce: {{ recceOf(c.id).calls }} calls</span></div></div>
                <div class="racts">
                  <span class="btn sm" ng-class="{on: c.enabled}" ng-click="courseOn(c.id, !c.enabled)">{{ c.enabled ? 'timing on' : 'time it' }}</span>
                  <span class="btn sm" ng-class="{on: cs.laps.guided === c.id}" ng-click="guide(cs.laps.guided === c.id ? null : c.id)" title="ground markers lead you to its start line">{{ cs.laps.guided === c.id ? 'guiding: stop' : 'guide me' }}</span>
                  <span class="btn sm" ng-click="takeTo(c.id)" title="puts your car about 40 m before its start line, facing it">take me there</span>
                  <span class="btn sm" ng-if="c.enabled && !recceOf(c.id)" ng-class="{on: recceArmed(c.id)}" ng-click="recceArm(!recceArmed(c.id), c.id)" title="your next timed lap records the co-driver's calls on this course; later laps get exactly those calls at the same places">{{ recceArmed(c.id) ? 'recce armed: cancel' : 'recce next lap' }}</span>
                  <span class="btn sm" ng-if="recceOf(c.id)" ng-class="{warn: confirmKey === 'recce' + c.id}" ng-click="confirmDo('recce' + c.id, 'if coDriverCoach then coDriverCoach.recceClear(nil, ' + q(c.id) + ') end')" title="recce of {{ recceOf(c.id).date }}, {{ recceOf(c.id).covered }} m">{{ confirmKey === 'recce' + c.id ? 'click again' : 'clear recce' }}</span>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section class="scard wide">
          <h4>Analysis and recording</h4>
          <div class="srow" ng-if="d.model"><label>Better line</label>
            <div><div class="seg"><span class="btn" ng-repeat="m in [0.9, 0.95, 1]" ng-class="{on: d.model.margin === m}" ng-click="setOpt('margin', m)">{{ (m * 100).toFixed(0) }}% of the limit</span></div>
              <div class="seg" style="margin-top:0.35em"><span class="btn" ng-repeat="x in ['auto', 'rally', 'circuit']" ng-class="{on: d.model.styleSetting === x}" ng-click="setOpt('style', x)">{{ x }}{{ x === 'auto' && d.model.styleSetting === 'auto' ? ' (' + d.model.style + ')' : '' }}</span></div>
              <div class="shelp">Model: {{ modelText() }}. {{ carText() }}</div></div></div>
          <div class="srow"><label>Replay recording</label>
            <div><div class="seg"><span class="btn" ng-repeat="x in ['off', 'laps', 'always']" ng-class="{on: st.recordReplay === x}" ng-click="setOpt('recordReplay', x)">{{ x === 'laps' ? 'laps / stages only' : x }}</span></div>
              <div class="shelp">{{ replayHelp() }}</div></div></div>
          <div class="srow" ng-if="cs.storage"><label>Replays on disk</label>
            <div><div class="sval">{{ cs.storage.n }} file{{ cs.storage.n === 1 ? '' : 's' }}, {{ cs.storage.mb >= 1000 ? (cs.storage.mb / 1000).toFixed(1) + ' GB' : cs.storage.mb + ' MB' }} <span class="shelp">(telemetry and laps are kept either way)</span></div>
              <div class="tgl" style="margin-top:0.3em">
                <span class="btn sm" ng-repeat="a in ['week', 'month']" ng-if="cs.storage.older[a].n" ng-class="{warn: confirmKey === 'rpl' + a}"
                      ng-click="confirmDo('rpl' + a, 'if coDriverAnalysis then coDriverAnalysis.deleteOldReplays(' + q(a) + ') end')">{{ confirmKey === 'rpl' + a ? 'click again to delete ' + cs.storage.older[a].n + ' (' + cs.storage.older[a].mb + ' MB)' : 'delete those older than a ' + a }}</span>
                <span class="btn sm" ng-if="cs.storage.older.oldVersion.n" ng-class="{warn: confirmKey === 'rplver'}" title="BeamNG {{ cs.storage.version }} cannot play replays recorded by an older version; your telemetry, laps and analysis stay"
                      ng-click="confirmDo('rplver', 'if coDriverAnalysis then coDriverAnalysis.deleteOldReplays(&quot;oldVersion&quot;) end')">{{ confirmKey === 'rplver' ? 'click again to delete ' + cs.storage.older.oldVersion.n + ' (' + cs.storage.older.oldVersion.mb + ' MB)' : 'delete ' + cs.storage.older.oldVersion.n + ' from an older game version (' + cs.storage.older.oldVersion.mb + ' MB)' }}</span>
                <span class="shelp" ng-if="cs.storage.n && !cs.storage.older.week.n && !cs.storage.older.oldVersion.n">None older than a week.</span>
              </div></div></div>
        </section>
      </div>
    </div>
    <div class="msg" ng-if="d.error && !setOpen">{{ d.error }}</div>
    <div class="msg" ng-if="!d.error && !d.n && !setOpen">No analysis yet. Drive with the coach on, then choose Review analysis at the end.</div>

    <div class="main" ng-show="d.n && st.mode !== 'replay' && !setOpen">
      <div class="mapbox">
        <canvas class="map"></canvas>
        <div class="mapbtns"><span class="btn" ng-if="canOwnerMap()" ng-class="{on: mapMode === 'owner'}" ng-click="setMapMode(mapMode === 'owner' ? 'loss' : 'owner')" title="colour your line by which of the two laps was quicker on each 10 m of road">quicker lap</span><span class="btn" ng-if="canBalanceMap()" ng-class="{on: mapMode === 'balance'}" ng-click="setMapMode(mapMode === 'balance' ? 'loss' : 'balance')" title="colour your line by the car's balance: pushing wide (understeer) or the rear stepping out (oversteer)">balance</span><span class="btn" ng-click="mapAll()">whole drive</span></div>
        <div class="maplegend"><i style="background:#6fe08a"></i>better line<span ng-if="!ownerMap() && !balanceMap()"><i style="background:#ffa64d"></i>you (redder = losing time)</span><span ng-if="balanceMap()"><i style="background:#ff5a4a"></i>pushing wide<i style="background:#3fd0c9"></i>rear stepping out<i style="background:rgba(255,255,255,0.45)"></i>neutral<span ng-if="!d.model.steerGain"> (no steering input recorded: pushing wide not judged)</span></span><span ng-if="ownerMap()"><i style="background:#ffa64d"></i>L{{ curLap().n }} quicker<i style="background:#58b4ff"></i>{{ cmpLabel() }} quicker</span>
          <span class="dots"><b class="dg"></b>on pace <b class="dy"></b>small loss <b class="dr"></b>most to gain <b class="di"></b>incident</span></div>
      </div>
      <div class="side">
        <div class="laptab" ng-if="lapList().length">
          <div class="tt">LAP TIMES <span class="sub" style="letter-spacing:0; font-weight:400">sectors are thirds of the lap, purple is your best · click a lap to study it</span></div>
          <table>
            <tr><th></th><th>time</th><th>gap</th><th>S1</th><th>S2</th><th>S3</th><th>lost most at</th></tr>
            <tr class="lr" ng-repeat="l in lapList()" ng-class="{inv: !l.valid, cur: lapSel === l.key}" ng-click="selectLap(lapSel === l.key ? null : l.key)">
              <td>L{{ l.n }}<span class="star" ng-if="d.laps.ref === l.key"> ★</span></td>
              <td>{{ lapTime(l.time) }}</td>
              <td>{{ l.valid ? (l.delta > 0.005 ? '+' + l.delta.toFixed(2) : 'best') : (l.reason || 'invalid') }}</td>
              <td ng-repeat="s in list(l.sectors) track by $index" ng-class="{pb: l.valid && isBestSector(s, $index)}">{{ s >= 0 ? s.toFixed(2) : '–' }}</td>
              <td class="sub">{{ topText(l) }}</td>
            </tr>
          </table>
          <div class="sub" ng-if="d.laps.theoretical">Theoretical best {{ lapTime(d.laps.theoretical10 || d.laps.theoretical) }}: your best {{ d.laps.theoretical10 ? 10 : 50 }} m stretches of every valid lap joined up<span ng-if="d.laps.theoretical10"> ({{ lapTime(d.laps.theoretical) }} from 50 m ones)</span><span ng-if="d.laps.spread != null"> · laps within ±{{ d.laps.spread.toFixed(2) }} s of each other</span>.</div>
        </div>
        <div class="where" ng-if="stretchView()">
          <div class="tt">WHERE THE TIME IS <span class="sub" style="letter-spacing:0; font-weight:400">{{ stretchView().note }} · click one to zoom in</span></div>
          <div class="wr" ng-repeat="x in stretchView().lost" ng-class="{sel: selStretch === x}" ng-click="selectStretch(x)" title="{{ x.s0 }}-{{ x.s1 }} m along the best lap">
            <span class="wl">{{ x.where }}</span><span class="sub">{{ x.s1 - x.s0 }} m<span ng-if="stretchView().byLap"> · L{{ lapN(x.by) }}</span></span>
            <span class="wg">−{{ x.gain.toFixed(2) }} s</span><span class="sub">{{ x.rate.toFixed(2) }} s/100 m</span>
          </div>
          <div class="wr won" ng-repeat="x in stretchView().won" ng-class="{sel: selStretch === x}" ng-click="selectStretch(x)" title="{{ x.s0 }}-{{ x.s1 }} m along the best lap">
            <span class="wl">✓ {{ x.where }}</span><span class="sub">{{ x.s1 - x.s0 }} m</span>
            <span class="wg">{{ x.gain.toFixed(2) }} s quicker</span><span class="sub">{{ x.rate.toFixed(2) }} s/100 m</span>
          </div>
          <div class="sub" ng-if="!stretchView().lost.length && !stretchView().won.length">No stretch of 0.02 s or more between these laps.</div>
        </div>
        <div class="good" ng-if="list(d.strengths).length && lapSel == null">
          <div class="tt">GOING WELL</div>
          <div class="tip" ng-repeat="t in list(d.strengths)">✓ {{ t.text }}
            <span class="refs"><span class="ref" ng-repeat="id in list(t.corners)" ng-click="select(id)">{{ id }}</span></span></div>
        </div>
        <div class="tips" ng-if="list(d.tips).length && lapSel == null">
          <div class="tt">NEXT DRIVE, TRY</div>
          <div class="tip" ng-repeat="t in list(d.tips)">{{ t.text }}
            <span class="refs"><span class="ref" ng-repeat="id in list(t.corners)" ng-click="select(id)">{{ id }}</span></span></div>
        </div>
        <div class="lhdr">
          <span class="tt">CORNERS</span><span class="grow"></span>
          <span class="btn" ng-class="{on: sortBy === 'order'}" ng-click="setSort('order')">in order</span>
          <span class="btn" ng-class="{on: sortBy === 'loss'}" ng-click="setSort('loss')">by time lost</span>
        </div>
        <div class="list">
          <div class="row" ng-repeat="c in ranked" ng-class="{sel: c.id === selId}" ng-click="select(c.id)">
            <span class="num" ng-class="lossClass(c)">{{ cornerLabel(c) }}</span>
            <div class="rb">
              <div class="nm">{{ c.unneeded ? 'Brake zone' : (c.dir === 'left' ? 'Left' : 'Right') }}<span ng-if="c.radius && !c.unneeded"> · R {{ c.radius }} m</span><span ng-if="c.gradePct <= -3 || c.gradePct >= 3"> · {{ c.gradePct > 0 ? c.gradePct + '% uphill' : (-c.gradePct) + '% downhill' }}</span>
                <span class="sub"> · {{ spd(c.minSpeed) }} / {{ spd(c.idealMin) }} {{ d.unit }}</span>
                <span class="tn" ng-if="lapSel == null && c.lap"> · L{{ lapN(c.lap) }}<span ng-if="c.turn"> T{{ c.turn }}</span></span></div>
              <div class="vb" ng-if="cmpText(c)">{{ cmpText(c) }}</div>
              <div class="vb" ng-if="c.vsBest != null">{{ c.vsBest < 0.03 ? '★ your best pass of this turn' : '+' + c.vsBest.toFixed(2) + ' s slower than your best pass here (lap ' + lapN(c.bestLap) + ')' }}</div>
              <div class="gd" ng-repeat="g in list(c.good)">✓ {{ g }}</div>
              <div class="vb" ng-if="c.balance && !c.incident">Balance: {{ c.balance }}</div>
              <div class="nt" ng-class="{inc: c.incident}" ng-if="c.loss >= 0.1 || !list(c.good).length"><span ng-if="c.incident">⚠ </span>{{ c.note }}</div>
            </div>
            <span class="ls" ng-class="lossClass(c)">{{ c.incident ? 'incident' : (c.loss > 0.05 ? '−' + c.loss.toFixed(2) + ' s' : 'on pace') }}</span>
            <span class="btn rp" ng-if="c.hasReplay" title="replay this corner" ng-click="replay(c.id); $event.stopPropagation()">▶</span>
          </div>
        </div>
        <div class="eng">
          <span class="mic" ng-class="{on: eng.listening, off: !eng.online}" ng-mousedown="talkDown($event)" ng-mouseup="talkUp()" ng-mouseleave="talkUp()"
                title="Hold and ask, release to send">{{ eng.listening ? '● listening' : (eng.busy ? '…' : '🎙') }}</span>
          <input class="q" type="text" ng-model="eng.q" placeholder="Ask your engineer…" ng-keydown="$event.keyCode === 13 && askTyped()">
          <span class="btn prim" ng-click="debrief()" title="engineer debrief">debrief</span>
        </div>
        <div class="ans" ng-show="lastAnswer()">
          <span class="aq">{{ lastAnswer().q }}</span><span class="aa">{{ lastAnswer().a }}</span><span class="src">{{ lastAnswer().source }}</span>
        </div>
      </div>
    </div>

    <div class="charts" ng-show="d.n && (showCharts || st.mode === 'replay')">
      <canvas class="base"></canvas>
      <canvas class="over"></canvas>
    </div>
    <div class="foot" ng-show="d.n && (showCharts || st.mode === 'replay')">
      <span class="ro" ng-if="ro">
        <b>{{ ro.km }}</b> · Δ <b>{{ ro.delta }}</b> · speed <b class="y">{{ ro.v }}</b> / <b class="g">{{ ro.iv }}</b> {{ d.unit }} ·
        throttle <b>{{ ro.thr }}%</b> · brake <b>{{ ro.brk }}%</b> (better <b class="g">{{ ro.ib }}%</b>) · steer <b>{{ ro.str }}</b> · gear <b>{{ ro.gear }}</b> · {{ ro.lat }} g lat
      </span>
      <span class="grow"></span>
      <span class="hint">drag to scrub · wheel to zoom · right-drag to pan · double-click to reset</span>
      <span class="btn" ng-if="d.hasReplay && st.mode !== 'replay'" ng-click="replayHere()">▶ replay from cursor</span>
    </div>
  </div>
</div>`,
    replace: true,
    restrict: 'EA',
    link: function (scope, element) {
      const root = element[0]
      // hidden or not, only the card itself takes clicks
      function setClickThrough () {
        let e = root.parentElement
        for (let i = 0; e && i < 8; i++, e = e.parentElement) {
          e.style.pointerEvents = 'none'
          if (e.classList && e.classList.contains('overlay-item')) break
        }
      }
      setTimeout(setClickThrough, 0)

      scope.st = { open: false }
      scope.d = {}
      scope.ranked = []
      scope.selId = null
      scope.ro = null
      scope.list = function (x) { return Array.isArray(x) ? x : [] }
      const lua = function (cmd) { bngApi.engineLua('if coDriverAnalysis then coDriverAnalysis.' + cmd + ' end') }

      let P = null          // the model's 4 m grid (columns)
      let T = null          // your inputs at full rate (columns, same distance axis)
      let view = { s0: 0, s1: 1 }
      let cursor = 0        // grid index nearest the cursor
      let cursorS = 0       // cursor distance (m)
      let mapView = null    // { x0, y0, x1, y1 } world bounds
      let unitMul = 3.6

      scope.clock = function (s) {
        if (s == null) return '-'
        const m = Math.floor(s / 60), r = s - m * 60
        return m + ':' + (r < 10 ? '0' : '') + r.toFixed(1)
      }
      scope.spd = function (v) { return v == null ? '-' : Math.round(v * unitMul) }
      scope.modelText = function () {
        const m = scope.d.model
        if (!m) return ''
        let t = m.lat + ' g cornering'
        if (m.aeroAt150 > 0.02) t += ' (+' + Math.round(m.aeroAt150 * 100) + '% aero at 150 km/h)'
        t += ', ' + m.brk + ' g braking' + (m.surface ? ' on ' + m.surface : '') + ' · aims at ' + Math.round(m.margin * 100) + '% · ' + m.style
        return t
      }
      scope.carText = function () {
        const m = scope.d.model
        if (!m) return ''
        const a = []
        if (m.powerKW) a.push(m.powerKW + ' kW' + (m.powerMeasuredKW ? ' (about ' + m.powerMeasuredKW + ' kW measured at the wheels, ' + m.powerMeasuredKmh + ' km/h)' : ''))
        else if (m.powerMeasuredKW) a.push('about ' + m.powerMeasuredKW + ' kW measured at the wheels')
        if (m.mass) a.push(m.mass + ' kg')
        if (m.driven) a.push(m.driven)
        if (m.abs != null) a.push(m.abs ? 'ABS' : 'no ABS')
        if (m.brakeCap) a.push('brakes up to ' + m.brakeCap + ' g')
        if (m.walls) a.push(m.clipFixes ? 'walls checked, line moved off ' + m.clipFixes + ' points' : 'walls checked')
        return a.length ? 'Car: ' + a.join(', ') : ''
      }
      scope.sessions = []
      scope.lapTime = function (s) { const m = Math.floor(s / 60), r = (s - m * 60).toFixed(3); return m + ':' + (r < 10 ? '0' : '') + r }
      scope.dur = function (secs) { const m = Math.floor((secs || 0) / 60), r = Math.round((secs || 0) - m * 60); return m + ':' + (r < 10 ? '0' : '') + r }
      scope.sessOpen = false
      scope.toggleSessions = function () {
        scope.sessOpen = !scope.sessOpen
        if (scope.sessOpen) { lua('requestSessions()'); if (scope.setOpen) scope.toggleSettings() }
      }
      scope.openSession = function (name) {
        scope.sessOpen = false
        lua('loadSession(' + JSON.stringify(String(name)) + ')')
      }
      scope.$on('CoDriverAnalysisSessions', function (e, list) {
        scope.$evalAsync(function () { scope.sessions = scope.list(list) })
      })
      scope.replayHelp = function () {
        const m = scope.st.recordReplay
        const n = scope.st.replayFiles
        const files = n != null ? ' ' + n + ' replay file' + (n === 1 ? '' : 's') + ' kept (never deleted automatically).' : ''
        if (m === 'off') return 'Telemetry only: no corner replays, best frame rate.' + files
        if (m === 'always') return 'Every drive (costs about 1.7 ms per frame while driving).' + files
        return 'Timed laps (and the run-up to a start line), GPS stages, and drives you arm with the "record replay" hotkey.' + files
      }
      scope.setOpt = function (k, v) { lua('setOption("' + k + '", ' + (typeof v === 'number' ? v : '"' + v + '"') + ')'); reqSettings() }

      // ---------- settings (coach, laps, analysis and engineer; each keeps its own file) ----------
      scope.cs = null
      scope.confirmKey = null
      scope.toggles = {
        codriver: [{ k: 'distanceCalls', label: 'distance calls', tip: '"two hundred, three left" when a corner is called from far away' },
          { k: 'crests', label: 'crests', tip: 'call crests and jumps' },
          { k: 'consoleMap', label: "map on the car's screen", tip: 'draw the road ahead on the navigation screen, when the car has one' },
          { k: 'frameScreen', label: 'tilt view to that screen', tip: 'tilt the driver camera just enough to see the navigation screen (once per car)' }],
        voice: [{ k: 'chatter', label: 'chatter', tip: 'spoken slide, shift, stage and debrief lines (when the voicepack has them)' },
          { k: 'toasts', label: 'calls as messages', tip: 'also show each call in the Messages app' }],
        aids: [{ k: 'brakeVoice', label: 'spoken brake cues', tip: '"brake" when you reach the brake point' },
          { k: 'carControl', label: 'slide hints', tip: 'hints on the strip when the car slides or the steering saws' }],
      }
      scope.q = function (s) { return JSON.stringify(String(s).replace(/[\u0000-\u001f\u007f]|[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/g, ' ')) }
      scope.near = function (a, b) { return Math.abs((a || 0) - b) < 0.01 }
      function reqSettings () { setTimeout(function () { lua('requestSettings()') }, 150) }
      scope.toggleSettings = function () {
        scope.setOpen = !scope.setOpen
        if (scope.setOpen) { lua('requestSettings()'); scope.sessOpen = false } else setTimeout(redrawAll, 30)
      }
      scope.coachCmd = function (cmd) { bngApi.engineLua('if coDriverCoach then coDriverCoach.' + cmd + ' end'); reqSettings() }
      scope.coachOpt = function (k, v) { scope.coachCmd('setOption(' + scope.q(k) + ', ' + (typeof v === 'string' ? scope.q(v) : String(v)) + ')') }
      scope.showCourses = false
      // official courses: the timed ones first, then the nearest
      scope.courseList = function () {
        return scope.list(scope.cs && scope.cs.laps && scope.cs.laps.courses).slice().sort(function (a, b) {
          if (a.enabled !== b.enabled) return a.enabled ? -1 : 1
          return (a.away == null ? 1e12 : a.away) - (b.away == null ? 1e12 : b.away)
        })
      }
      scope.awayText = function (m) { return m < 100 ? 'you are at its start' : (m < 1000 ? Math.round(m / 10) * 10 + ' m away' : (m / 1000).toFixed(1) + ' km away') }
      // getting to a start line: ground markers there, or the car put just before it (the panel closes so you can drive)
      scope.guide = function (id) {
        bngApi.engineLua('if coDriverLaps then coDriverLaps.guideToStart(' + (id ? scope.q(id) : 'nil') + ') end')
        if (id) lua('close()'); else reqSettings()
      }
      scope.takeTo = function (id) { bngApi.engineLua('if coDriverLaps then coDriverLaps.takeToStart(' + scope.q(id) + ') end'); lua('close()') }
      scope.gripNote = function () { const t = scope.gripText(); return t ? t.replace(/^, /, '').replace(/^./, c => c.toUpperCase()) + '.' : '' }
      scope.recceOf = function (id) { const r = scope.cs && scope.cs.laps && scope.cs.laps.recce; return r && r[id] ? r[id] : null }
      // recce armed (or recording) for this route
      scope.recceArmed = function (id) {
        const s = scope.cs && scope.cs.laps && scope.cs.laps.recceState
        return !!(s && ((s.armed && s.armedRoute === id) || (s.recording && s.recording.route === id)))
      }
      scope.recceArm = function (on, id) { bngApi.engineLua('if coDriverCoach then coDriverCoach.recceArm(' + (on ? 'true, ' + scope.q(id) : 'false') + ') end'); reqSettings() }
      scope.coursesOn = function () { return scope.list(scope.cs && scope.cs.laps && scope.cs.laps.courses).filter(c => c.enabled).length }
      scope.courseOn = function (id, on) { bngApi.engineLua('if coDriverLaps then coDriverLaps.setCourseEnabled(' + scope.q(id) + ', ' + (on ? 'true' : 'false') + ') end'); reqSettings() }
      scope.lapsOpt = function (k, v) { bngApi.engineLua('if coDriverLaps then coDriverLaps.setOption(' + scope.q(k) + ', ' + scope.q(v) + ') end'); reqSettings() }
      let confirmTimer = null
      // things that delete: the first click asks, the second (within 4 s) does it
      scope.confirmDo = function (key, cmd) {
        if (scope.confirmKey !== key) {
          scope.confirmKey = key
          clearTimeout(confirmTimer)
          confirmTimer = setTimeout(function () { scope.$evalAsync(function () { scope.confirmKey = null }) }, 4000)
          return
        }
        scope.confirmKey = null
        bngApi.engineLua(cmd)
        reqSettings()
      }
      scope.gripText = function () {
        const g = scope.cs && scope.cs.coach && scope.cs.coach.grip
        if (!g) return ''
        if (g.legacy) return ', an older learned estimate (refined after 6 clean corners)'
        return g.corners ? ', learned from your ' + g.corners + ' cleanest corners in this car' : ' (surface defaults)'
      }
      scope.$on('CoDriverSettings', function (e, s) { scope.$evalAsync(function () { scope.cs = s || null }) })
      scope.$on('CoDriverOpenSettings', function () {
        scope.$evalAsync(function () { scope.setOpen = true; scope.sessOpen = false })
      })
      // corner list (and replay prev/next) in turn order, or by time lost
      const store = { get: k => { try { return localStorage.getItem(k) } catch (e) { return null } },
        set: (k, v) => { try { localStorage.setItem(k, v) } catch (e) {} } }
      scope.sortBy = store.get('cda.sortBy') === 'loss' ? 'loss' : 'order'
      function sortCorners (cs) {
        return cs.slice().sort(scope.sortBy === 'loss' ? (a, b) => b.loss - a.loss : (a, b) => a.id - b.id)
      }
      scope.setSort = function (k) {
        scope.sortBy = k
        store.set('cda.sortBy', k)
        scope.ranked = sortCorners(cornersInScope())
      }
      scope.lossClass = function (c) { return c.incident ? 'inc' : (c.loss > 0.5 ? 'bad' : (c.loss > 0.15 ? 'mid' : 'ok')) }
      scope.showCharts = store.get('cda.charts') === '1'
      scope.toggleCharts = function () {
        scope.showCharts = !scope.showCharts
        store.set('cda.charts', scope.showCharts ? '1' : '0')
        setTimeout(redrawAll, 30)
      }
      scope.cornerById = function (id) {
        if (!id || !scope.d.corners) return null
        return scope.list(scope.d.corners).find(c => c.id === id) || null
      }

      // ---------- laps ----------
      // lapSel: the key (1-based index) of the lap being studied, or null for the whole drive
      scope.lapSel = null
      scope.lapList = function () { return scope.list(scope.d.laps && scope.d.laps.list) }
      scope.curLap = function () {
        if (scope.lapSel == null) return null
        return scope.lapList().find(l => l.key === scope.lapSel) || null
      }
      scope.lapN = function (key) { const l = scope.lapList().find(x => x.key === key); return l ? l.n : '?' }
      scope.lapSummary = function () {
        const L = scope.d.laps
        if (!L) return ''
        const best = scope.lapList().find(l => l.key === L.ref)
        const a = []
        a.push(L.valid + ' valid of ' + scope.lapList().length)
        if (best) a.push('best ' + scope.lapTime(best.time))
        if (L.theoretical10 || L.theoretical) a.push('theoretical ' + scope.lapTime(L.theoretical10 || L.theoretical))
        if (L.length) a.push((L.length / 1000).toFixed(2) + ' km')
        return a.join(' · ')
      }
      scope.isBestSector = function (s, k) {
        const b = scope.d.laps && scope.list(scope.d.laps.sectors)
        return b && s >= 0 && b[k] >= 0 && Math.abs(s - b[k]) < 0.006
      }
      scope.topText = function (l) { return l ? scope.list(l.top).map(x => 'T' + x.turn + ' +' + x.loss.toFixed(2) + ' s').join(', ') : '' }
      // corners are numbered through the drive; studying a lap, they are the route's turns
      scope.cornerLabel = function (c) {
        if (!c) return ''
        if (scope.lapSel == null) return String(c.id)
        return c.turn ? 'T' + c.turn : '#' + c.id // # = not one of the route's turns (found in this lap only)
      }
      function cornersInScope () {
        const cs = scope.list(scope.d.corners)
        return scope.lapSel == null ? cs : cs.filter(c => c.lap === scope.lapSel)
      }
      function lapRange () { // grid indices (0-based) of the lap being studied, or the whole drive
        const l = scope.curLap()
        return l && P ? [Math.max(0, l.i0 - 1), Math.min(P.s.length - 1, l.i1 - 1)] : [0, P ? P.s.length - 1 : 0]
      }
      // ---------- comparing two laps ----------
      // cmpSel: the lap the studied one is compared with (key); null means the best lap
      scope.cmpSel = null
      let cmpCache = null
      scope.cmpKey = function () { return scope.cmpSel != null ? scope.cmpSel : (scope.d.laps && scope.d.laps.ref) }
      scope.setCompare = function (key) {
        scope.cmpSel = scope.d.laps && key === scope.d.laps.ref ? null : key
        cmpCache = null
        clearStretch()
        redrawAll()
      }
      scope.gapText = function (x) { return (x >= 0 ? '+' : '−') + Math.abs(x).toFixed(2) }
      scope.cmpLapTime = function () {
        if (scope.cmpSel === 'ever') return scope.d.laps && scope.d.laps.bestEver ? scope.d.laps.bestEver.time : null
        const l = scope.lapList().find(x => x.key === scope.cmpSel); return l ? l.time : null
      }
      // the route's best ever (kept from another drive): one more thing to compare with
      scope.everOk = function () { const e = scope.d.laps && scope.d.laps.bestEver; return !!(e && !e.same && Array.isArray(e.tAt)) }
      scope.everSame = function () { const e = scope.d.laps && scope.d.laps.bestEver; return !!(e && e.same) }
      scope.cmpLabel = function () { const k = scope.cmpKey(); return k === 'ever' ? 'best ever' : 'L' + scope.lapN(k) }
      // The studied lap against the compared one at the same place on the road (station along the
      // best lap): the time gap at every point of the studied lap and the compared lap's speed there.
      function compareSeries () {
        const A = scope.curLap(), bk = scope.cmpKey()
        if (bk === 'ever') return everSeries(A)
        if (!A || !P || !bk || bk === A.key || !Array.isArray(P.st) || !Array.isArray(P.ld) || A.delta == null) return null
        const B = scope.lapList().find(l => l.key === bk)
        if (!B || B.delta == null) return null
        if (cmpCache && cmpCache.a === A.key && cmpCache.b === bk) return cmpCache
        const n = P.s.length, d = new Array(n).fill(0), v = new Array(n).fill(NaN)
        const b0 = B.i0 - 1, b1 = Math.min(n - 1, B.i1 - 1)
        let j = b0
        for (let i = A.i0 - 1; i <= Math.min(n - 1, A.i1 - 1); i++) {
          const s = P.st[i]
          while (j < b1 - 1 && P.st[j + 1] < s) j++
          const j2 = Math.min(b1, j + 1)
          const f = P.st[j2] > P.st[j] ? Math.max(0, Math.min(1, (s - P.st[j]) / (P.st[j2] - P.st[j]))) : 0
          d[i] = P.ld[i] - (P.ld[j] + (P.ld[j2] - P.ld[j]) * f)
          v[i] = P.v[j] + (P.v[j2] - P.v[j]) * f
        }
        cmpCache = { a: A.key, b: bk, d, v, label: 'L' + B.n, label2: 'lap ' + B.n, b0, b1 }
        return cmpCache
      }
      // against the best ever: its time and speed at every 10 m cell boundary, at this lap's stations
      function everSeries (A) {
        const E = scope.d.laps && scope.d.laps.bestEver, cm = scope.d.laps && scope.d.laps.cellM
        if (!A || !P || !E || !Array.isArray(E.tAt) || !cm || !Array.isArray(P.st) || A.delta == null) return null
        if (cmpCache && cmpCache.a === A.key && cmpCache.b === 'ever') return cmpCache
        const at = (arr, s) => {
          const x = s / cm, k = Math.max(0, Math.min(arr.length - 2, Math.floor(x))), f = Math.max(0, Math.min(1, x - k))
          const a = arr[k], b = arr[k + 1]
          return a >= 0 && b >= 0 ? a + (b - a) * f : NaN
        }
        const n = P.s.length, d = new Array(n).fill(0), v = new Array(n).fill(NaN)
        for (let i = A.i0 - 1; i <= Math.min(n - 1, A.i1 - 1); i++) {
          const te = at(E.tAt, P.st[i])
          d[i] = isNaN(te) ? 0 : (P.t[i] - A.t0) - te
          v[i] = Array.isArray(E.vAt) ? at(E.vAt, P.st[i]) : NaN
        }
        cmpCache = { a: A.key, b: 'ever', d, v, label: 'best ever', label2: 'your best ever', line: E.line }
        return cmpCache
      }
      scope.cmpText = function (c) {
        if (scope.cmpSel == null || scope.cmpSel === 'ever' || !c || !c.turn || !scope.d.laps) return ''
        const tn = scope.list(scope.d.laps.turns)[c.turn - 1]
        if (!tn) return ''
        const a = scope.list(tn.times)[scope.lapSel - 1], b = scope.list(tn.times)[scope.cmpSel - 1]
        if (!(a >= 0 && b >= 0)) return ''
        const x = a - b
        return 'T' + c.turn + ' ' + a.toFixed(2) + ' s, lap ' + scope.lapN(scope.cmpSel) + ' ' + b.toFixed(2) + ' s (' + (x >= 0 ? '+' : '−') + Math.abs(x).toFixed(2) + ')'
      }
      // ---------- where the time is ----------
      // the studied lap against the compared one (lapStretches above); the best lap against the
      // quickest valid lap of each cell (from the analysis, each stretch with the lap that did it)
      let svCache = null, strSel = null // strSel: the clicked stretch's grid range on the studied lap
      scope.selStretch = null
      scope.stretchView = function () {
        const A = scope.curLap(), L = scope.d.laps
        if (!A || !L) return null
        const bk = scope.cmpKey(), key = A.key + ':' + bk
        if (svCache && svCache.key === key && svCache.laps === L) return svCache.v
        let v = null
        if (bk === 'ever') {
          const E = L.bestEver
          const r = E && lapStretches({ list: [A, { tAt: E.tAt }], turns: L.turns, cells: L.cells, cellM: L.cellM }, 1, 2)
          if (r) v = { note: 'L' + A.n + ' against your best ever (' + E.date + '), sharpest first', lost: r.lost, won: r.won, own: r.own }
        } else if (bk === A.key) {
          const lost = scope.list(A.stretches)
          if (lost.length) v = { note: 'where your other laps were quicker than L' + A.n + ', sharpest first', lost, won: [], byLap: true }
        } else {
          const r = lapStretches(L, A.key, bk)
          if (r) v = { note: 'L' + A.n + ' against L' + scope.lapN(bk) + ', sharpest first', lost: r.lost, won: r.won, own: r.own }
        }
        svCache = { key, laps: L, v }
        return v
      }
      function clearStretch () { scope.selStretch = null; strSel = null }
      scope.selectStretch = function (x) {
        const A = scope.curLap()
        if (!A || !P || !Array.isArray(P.st)) return
        const a1 = Math.min(P.s.length - 1, A.i1 - 1)
        let ia = A.i0 - 1
        while (ia < a1 && P.st[ia] < x.s0) ia++
        let ib = ia
        while (ib < a1 && P.st[ib] < x.s1) ib++
        scope.selStretch = x; strSel = { ia, ib }
        scope.selId = null
        const a = P.s[ia], b = P.s[ib], pad = Math.max(30, (b - a) * 0.3)
        setView(a - pad, b + pad)
        placeCursor(a)
        mapView = boundsOf(ia - 6, ib + 6, 15)
        redrawAll()
      }
      // map colours in compare: time lost (default) or which lap was quicker on each cell
      scope.mapMode = ({ owner: 'owner', balance: 'balance' })[store.get('cda.mapMode')] || 'loss'
      scope.canOwnerMap = function () { const v = scope.stretchView(); return !!(v && v.own) }
      scope.ownerMap = function () { return scope.mapMode === 'owner' && scope.canOwnerMap() }
      // the car's balance per point (analysis 'bal': 0 neutral, 1 understeer, 2 oversteer); older sessions have none
      scope.canBalanceMap = function () { return !!(P && Array.isArray(P.bal) && P.bal.length) }
      scope.balanceMap = function () { return scope.mapMode === 'balance' && scope.canBalanceMap() }
      scope.setMapMode = function (m) { scope.mapMode = m; store.set('cda.mapMode', m); drawMap() }

      scope.selectLap = function (key) {
        scope.lapSel = key
        if (scope.cmpSel === key) scope.cmpSel = null
        cmpCache = null
        scope.selId = null
        clearStretch()
        scope.ranked = sortCorners(cornersInScope())
        if (P) {
          const r = lapRange()
          view = { s0: P.s[r[0]], s1: Math.max(P.s[r[0]] + 40, P.s[r[1]]) }
          placeCursor(P.s[r[0]])
          mapView = boundsOf(r[0], r[1], 20)
          redrawAll()
        }
      }
      scope.replayLap = function () { const l = scope.curLap(); if (l) lua('replayAt(' + (l.t0 - 1).toFixed(3) + ')') }

      // ---------- data ----------
      function setData (d) {
        scope.d = d || {}
        P = d && d.points && Array.isArray(d.points.s) ? d.points : null
        T = d && d.trace && Array.isArray(d.trace.s) && d.trace.s.length ? d.trace : null
        unitMul = d && d.unit === 'mph' ? 2.23694 : 3.6
        const keepView = P && setData.last && setData.last.n === d.n && setData.last.date === d.date
        if (!keepView) { scope.selId = null; scope.lapSel = null; scope.cmpSel = null }
        cmpCache = null
        svCache = null
        clearStretch()
        if (scope.lapSel != null && !scope.curLap()) scope.lapSel = null
        const openOnBest = !keepView && d && d.laps && d.laps.ref
        scope.ranked = sortCorners(cornersInScope())
        setData.last = { n: d && d.n, date: d && d.date }
        if (P && !keepView) {
          view = { s0: P.s[0], s1: P.s[P.s.length - 1] }
          cursor = 0; cursorS = P.s[0]
          mapAllBounds()
        }
        // a drive with laps opens on the best lap (the lap table and "all" are one click away)
        if (P && openOnBest) scope.selectLap(d.laps.ref)
        setTimeout(redrawAll, 30)
      }

      function idxAtS (s) {
        if (!P) return 0
        let lo = 0, hi = P.s.length - 1
        while (hi - lo > 1) { const m = (lo + hi) >> 1; if (P.s[m] < s) lo = m; else hi = m }
        return Math.abs(P.s[hi] - s) < Math.abs(P.s[lo] - s) ? hi : lo
      }
      // first index with arr[i] >= x
      function lowerBound (arr, x) {
        let lo = 0, hi = arr.length
        while (lo < hi) { const m = (lo + hi) >> 1; if (arr[m] < x) lo = m + 1; else hi = m }
        return lo
      }
      function traceIdx (s) {
        if (!T) return -1
        const i = Math.min(T.s.length - 1, lowerBound(T.s, s))
        return i > 0 && Math.abs(T.s[i - 1] - s) < Math.abs(T.s[i] - s) ? i - 1 : i
      }
      // session time <-> distance, interpolated on the grid
      function sAtT (t) {
        if (!P) return 0
        const i = lowerBound(P.t, t)
        if (i <= 0) return P.s[0]
        if (i >= P.t.length) return P.s[P.s.length - 1]
        const f = (t - P.t[i - 1]) / Math.max(1e-6, P.t[i] - P.t[i - 1])
        return P.s[i - 1] + (P.s[i] - P.s[i - 1]) * Math.max(0, Math.min(1, f))
      }
      function tAtS (s) {
        if (!P) return 0
        const i = lowerBound(P.s, s)
        if (i <= 0) return P.t[0]
        if (i >= P.s.length) return P.t[P.t.length - 1]
        const f = (s - P.s[i - 1]) / Math.max(1e-6, P.s[i] - P.s[i - 1])
        return P.t[i - 1] + (P.t[i] - P.t[i - 1]) * Math.max(0, Math.min(1, f))
      }

      function boundsOf (i0, i1, pad) {
        let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity
        for (let i = Math.max(0, i0); i <= Math.min(P.s.length - 1, i1); i++) {
          for (const [x, y] of [[P.x[i], P.y[i]], [P.lx[i], P.ly[i]], [P.rx[i], P.ry[i]]]) {
            if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y
          }
        }
        return { x0: x0 - pad, y0: y0 - pad, x1: x1 + pad, y1: y1 + pad }
      }
      function mapAllBounds () { const r = lapRange(); mapView = boundsOf(r[0], r[1], 20) }
      scope.mapAll = function () { if (P) { mapAllBounds(); drawMap() } }

      // ---------- canvases ----------
      function canv (cls) { return root.querySelector('canvas.' + cls) }
      function prep (c) {
        if (!c) return null
        const r = c.getBoundingClientRect()
        const dpr = window.devicePixelRatio || 1
        const w = Math.max(10, Math.round(r.width * dpr)), h = Math.max(10, Math.round(r.height * dpr))
        if (c.width !== w || c.height !== h) { c.width = w; c.height = h }
        const ctx = c.getContext('2d')
        ctx.setTransform(1, 0, 0, 1, 0, 0)
        ctx.clearRect(0, 0, w, h)
        return { ctx, w, h, dpr }
      }
      function fontPx () { return parseFloat(getComputedStyle(root).fontSize) || 12 }

      // loss rate per 4 m as a colour: white-ish when on pace, orange to red when losing
      function lossColor (i) {
        const j = Math.min(i + 1, P.d.length - 1)
        const r = Math.max(0, Math.min(1, (P.d[j] - P.d[i]) / 0.03))
        const g = Math.round(200 - 150 * r), b = Math.round(90 - 60 * r)
        return 'rgb(255,' + g + ',' + b + ')'
      }

      function drawMap () {
        const m = prep(canv('map'))
        if (!m || !P || !mapView) return
        const { ctx, w, h, dpr } = m
        const bw = mapView.x1 - mapView.x0, bh = mapView.y1 - mapView.y0
        const sc = Math.min(w / bw, h / bh)
        const ox = (w - bw * sc) / 2, oy = (h - bh * sc) / 2
        const X = x => ox + (x - mapView.x0) * sc
        const Y = y => h - (oy + (y - mapView.y0) * sc)
        const n = P.s.length
        const rg = lapRange(), ra = rg[0], rb = rg[1]
        if (scope.lapSel != null) { // the rest of the drive, faint
          ctx.strokeStyle = 'rgba(255,255,255,0.12)'; ctx.lineWidth = Math.max(1, dpr)
          ctx.beginPath()
          for (let i = 0; i < n; i++) {
            if (i === 0 || P.seg[i] !== P.seg[i - 1]) ctx.moveTo(X(P.x[i]), Y(P.y[i])); else ctx.lineTo(X(P.x[i]), Y(P.y[i]))
          }
          ctx.stroke()
        }
        // road band
        ctx.fillStyle = '#2a2f37'
        for (let i = ra; i < rb; i++) {
          if (P.seg[i] !== P.seg[i + 1]) continue
          ctx.beginPath()
          ctx.moveTo(X(P.lx[i]), Y(P.ly[i])); ctx.lineTo(X(P.lx[i + 1]), Y(P.ly[i + 1]))
          ctx.lineTo(X(P.rx[i + 1]), Y(P.ry[i + 1])); ctx.lineTo(X(P.rx[i]), Y(P.ry[i]))
          ctx.closePath(); ctx.fill()
        }
        const band = (i0, i1, col) => {
          ctx.fillStyle = col
          for (let i = i0; i < i1; i++) {
            if (i < 0 || i >= n - 1 || P.seg[i] !== P.seg[i + 1]) continue
            ctx.beginPath()
            ctx.moveTo(X(P.lx[i]), Y(P.ly[i])); ctx.lineTo(X(P.lx[i + 1]), Y(P.ly[i + 1]))
            ctx.lineTo(X(P.rx[i + 1]), Y(P.ry[i + 1])); ctx.lineTo(X(P.rx[i]), Y(P.ry[i]))
            ctx.closePath(); ctx.fill()
          }
        }
        const sel = scope.cornerById(scope.selId)
        if (sel) band(sel.i0 - 1, sel.i1 - 1, 'rgba(58,123,213,0.28)') // the selected corner
        if (strSel) band(strSel.ia, strSel.ib, 'rgba(255,166,77,0.30)') // the clicked stretch
        const lw = Math.max(1.5 * dpr, Math.min(4 * dpr, sc * 0.6))
        // better line
        ctx.strokeStyle = 'rgba(111,224,138,0.9)'; ctx.lineWidth = lw; ctx.setLineDash([3 * lw, 2 * lw])
        ctx.beginPath()
        for (let i = ra; i <= rb; i++) {
          if (i === ra || P.seg[i] !== P.seg[i - 1]) ctx.moveTo(X(P.ix[i]), Y(P.iy[i])); else ctx.lineTo(X(P.ix[i]), Y(P.iy[i]))
        }
        ctx.stroke(); ctx.setLineDash([])
        // the compared lap's line (blue), under the studied one
        const cmpM = scope.curLap() ? compareSeries() : null
        const own = scope.ownerMap() ? scope.stretchView().own : null
        if (cmpM && !own) {
          ctx.strokeStyle = 'rgba(88,180,255,0.85)'; ctx.lineWidth = lw * 0.8
          ctx.beginPath()
          if (cmpM.line && Array.isArray(cmpM.line.x)) { // the best ever, from another drive
            for (let i = 0; i < cmpM.line.x.length; i++) {
              if (i === 0) ctx.moveTo(X(cmpM.line.x[i]), Y(cmpM.line.y[i])); else ctx.lineTo(X(cmpM.line.x[i]), Y(cmpM.line.y[i]))
            }
          } else {
            for (let i = cmpM.b0; i <= cmpM.b1; i++) {
              if (i === cmpM.b0 || P.seg[i] !== P.seg[i - 1]) ctx.moveTo(X(P.x[i]), Y(P.y[i])); else ctx.lineTo(X(P.x[i]), Y(P.y[i]))
            }
          }
          ctx.stroke()
        }
        // your line, coloured by time lost (or by the lap that was quicker on each 10 m cell)
        ctx.lineWidth = lw
        const cm = scope.d.laps && scope.d.laps.cellM
        for (let i = ra; i < rb; i++) {
          if (P.seg[i] !== P.seg[i + 1]) continue
          if (own) {
            const o = own[Math.max(1, Math.min(own.length - 1, Math.floor((P.st[i] + P.st[i + 1]) / 2 / cm) + 1))]
            ctx.strokeStyle = o === 2 ? '#ffa64d' : (o === 1 ? '#58b4ff' : 'rgba(255,255,255,0.35)')
          } else if (scope.balanceMap()) {
            const b = Math.max(P.bal[i] || 0, P.bal[i + 1] || 0)
            ctx.strokeStyle = b === 1 ? '#ff5a4a' : (b === 2 ? '#3fd0c9' : 'rgba(255,255,255,0.45)')
          } else ctx.strokeStyle = lossColor(i)
          ctx.beginPath(); ctx.moveTo(X(P.x[i]), Y(P.y[i])); ctx.lineTo(X(P.x[i + 1]), Y(P.y[i + 1])); ctx.stroke()
        }
        // brake points: ideal (green ring) and yours (orange)
        const fp = fontPx() * dpr
        if (sel) {
          const dot = (i, col, ideal, label) => {
            if (i == null) return
            const x = X(ideal ? P.ix[i - 1] : P.x[i - 1]), y = Y(ideal ? P.iy[i - 1] : P.y[i - 1])
            ctx.fillStyle = col; ctx.beginPath(); ctx.arc(x, y, lw * 1.8, 0, 7); ctx.fill()
            ctx.font = (0.9 * fp) + 'px Roboto'; ctx.fillText(label, x + lw * 2.5, y - lw * 2)
          }
          dot(sel.iBrakeIdeal, '#ff5a4a', true, 'brake here')
          dot(sel.iBrake, '#ffa64d', false, 'you braked')
          dot(sel.iApex, '#6fe08a', true, 'apex')
          dot(sel.iPickup, '#58b4ff', true, 'throttle')
        }
        // corner numbers
        ctx.font = 'bold ' + (1.0 * fp) + 'px Roboto'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle'
        for (const c of cornersInScope()) {
          const i = c.iApex - 1
          if (i < 0 || i >= n) continue
          const x = X(P.ix[i]), y = Y(P.iy[i])
          if (x < 0 || y < 0 || x > w || y > h) continue
          const label = scope.cornerLabel(c)
          ctx.fillStyle = c.incident ? '#5a606b' : (c.loss > 0.5 ? '#c4554a' : (c.loss > 0.15 ? '#b8912e' : '#3f9a5a'))
          ctx.beginPath(); ctx.arc(x, y, fp * (label.length > 2 ? 1.05 : 0.85), 0, 7); ctx.fill()
          if (c.id === scope.selId) { ctx.strokeStyle = '#9ec3ff'; ctx.lineWidth = fp * 0.2; ctx.stroke() }
          ctx.fillStyle = '#fff'; ctx.fillText(label, x, y)
        }
        ctx.textAlign = 'left'; ctx.textBaseline = 'alphabetic'
        // cursor
        if (cursor >= 0 && cursor < n) {
          ctx.fillStyle = '#6fe08a'; ctx.beginPath(); ctx.arc(X(P.ix[cursor]), Y(P.iy[cursor]), lw * 2, 0, 7); ctx.fill()
          ctx.fillStyle = '#fff'; ctx.strokeStyle = '#ffa64d'; ctx.lineWidth = lw
          ctx.beginPath(); ctx.arc(X(P.x[cursor]), Y(P.y[cursor]), lw * 2.4, 0, 7); ctx.fill(); ctx.stroke()
        }
      }

      // chart lanes: [key, share of height]
      const LANES = [['delta', 0.17], ['speed', 0.31], ['pedals', 0.24], ['steer', 0.16], ['gear', 0.12]]
      let laneBox = []
      function lanes (h, top) {
        const out = []; let y = top
        const gap = 4
        for (const [k, f] of LANES) { const hh = (h - top) * f; out.push({ k, y0: y + gap, y1: y + hh - gap }); y += hh }
        return out
      }
      let chartGeom = null
      function drawCharts () {
        const m = prep(canv('base'))
        if (!m || !P) return
        const { ctx, w, h, dpr } = m
        const fp = fontPx() * dpr
        const left = 4.2 * fp, right = 0.6 * fp, top = 1.3 * fp
        const X = s => left + (s - view.s0) / (view.s1 - view.s0) * (w - left - right)
        chartGeom = { left, right, w, dpr, top, h }
        laneBox = lanes(h, top)
        // corner shading and numbers
        ctx.font = 'bold ' + (0.85 * fp) + 'px Roboto'; ctx.textAlign = 'center'
        for (const c of cornersInScope()) {
          const a = P.s[Math.max(0, c.iBrakeIdeal - 1)], b = P.s[Math.min(P.s.length - 1, c.iExit - 1)]
          if (b < view.s0 || a > view.s1) continue
          ctx.fillStyle = c.id === scope.selId ? 'rgba(58,123,213,0.16)' : 'rgba(255,255,255,0.035)'
          ctx.fillRect(X(a), top, X(b) - X(a), h - top)
          ctx.fillStyle = c.id === scope.selId ? '#9ec3ff' : '#7d868f'
          ctx.fillText(scope.cornerLabel(c), (X(a) + X(b)) / 2, top - 0.3 * fp)
        }
        ctx.textAlign = 'left'
        if (strSel) { // the clicked stretch
          const a = P.s[strSel.ia], b = P.s[strSel.ib]
          ctx.fillStyle = 'rgba(255,166,77,0.13)'
          ctx.fillRect(X(a), top, X(b) - X(a), h - top)
        }
        // One series (S distances, arr values, seg segment ids). With more points than pixel
        // columns, each column is drawn as its min..max so short peaks never vanish.
        const plotW = w - left - right
        function line (L, S, arr, seg, lo, hi, col, width, dash, scale) {
          if (!S || !arr) return
          const Yv = v => L.y1 - (Math.max(lo, Math.min(hi, v * (scale || 1))) - lo) / (hi - lo) * (L.y1 - L.y0)
          const i0 = Math.max(0, lowerBound(S, view.s0) - 1), i1 = Math.min(S.length - 1, lowerBound(S, view.s1))
          ctx.strokeStyle = col; ctx.lineWidth = width * dpr; ctx.setLineDash(dash ? dash.map(x => x * dpr) : [])
          ctx.beginPath()
          if (i1 - i0 > plotW * 1.5) {
            let c0 = -1, mn = 0, mx = 0, first = true
            const flush = () => {
              if (c0 < 0) return
              const x = c0 + 0.5
              if (first) { ctx.moveTo(x, Yv(mn)); first = false } else ctx.lineTo(x, Yv(mn))
              if (mx !== mn) ctx.lineTo(x, Yv(mx))
            }
            for (let i = i0; i <= i1; i++) {
              if (i > i0 && seg[i] !== seg[i - 1]) { flush(); c0 = -1; first = true }
              const c = Math.floor(X(S[i])), v = arr[i]
              if (c !== c0) { flush(); c0 = c; mn = mx = v } else { if (v < mn) mn = v; if (v > mx) mx = v }
            }
            flush()
          } else {
            for (let i = i0; i <= i1; i++) {
              const x = X(S[i]), y = Yv(arr[i])
              if (i === i0 || seg[i] !== seg[i - 1]) ctx.moveTo(x, y); else ctx.lineTo(x, y)
            }
          }
          ctx.stroke(); ctx.setLineDash([])
        }
        function frame (L, label, lo, hi, fmt) {
          ctx.fillStyle = 'rgba(255,255,255,0.025)'; ctx.fillRect(left, L.y0, w - left - right, L.y1 - L.y0)
          ctx.fillStyle = '#9aa3ad'; ctx.font = (0.82 * fp) + 'px Roboto'
          ctx.fillText(label, 0.3 * fp, L.y0 + 0.9 * fp)
          ctx.fillStyle = '#5d666f'
          ctx.fillText(fmt(hi), 0.3 * fp, L.y0 + 1.9 * fp)
          ctx.fillText(fmt(lo), 0.3 * fp, L.y1 - 0.2 * fp)
        }
        const D = T || P // your inputs: full rate when the drive has them
        const i0 = Math.max(0, idxAtS(view.s0) - 1), i1 = Math.min(P.s.length - 1, idxAtS(view.s1) + 1)
        const cmp = scope.curLap() ? compareSeries() : null
        const lapD = !!cmp
        const DD = cmp ? cmp.d : P.d
        let dlo = Infinity, dhi = -Infinity, vhi = 0
        for (let i = i0; i <= i1; i++) {
          dlo = Math.min(dlo, DD[i]); dhi = Math.max(dhi, DD[i])
          vhi = Math.max(vhi, P.v[i] * unitMul, P.iv[i] * unitMul)
        }
        if (dhi - dlo < 0.2) dhi = dlo + 0.2
        vhi = Math.ceil(vhi / 20) * 20
        for (const L of laneBox) {
          if (L.k === 'delta') {
            frame(L, lapD ? 'Δ vs ' + cmp.label : 'Δ time (s)', dlo, dhi, v => v.toFixed(1))
            if (lapD && dlo < 0 && dhi > 0) { // zero line: above it you are behind your best lap
              const yz = L.y1 - (0 - dlo) / (dhi - dlo) * (L.y1 - L.y0)
              ctx.strokeStyle = 'rgba(255,255,255,0.15)'; ctx.lineWidth = dpr
              ctx.beginPath(); ctx.moveTo(left, yz); ctx.lineTo(w - right, yz); ctx.stroke()
            }
            line(L, P.s, DD, P.seg, dlo, dhi, lapD ? '#c792ea' : '#ffd166', 1.6)
          } else if (L.k === 'speed') {
            frame(L, 'speed', 0, vhi, v => Math.round(v))
            line(L, P.s, P.iv, P.seg, 0, vhi, '#6fe08a', 1.6, [5, 3], unitMul)
            if (cmp) line(L, P.s, cmp.v, P.seg, 0, vhi, '#58b4ff', 1.5, [3, 2], unitMul)
            line(L, D.s, D.v, D.seg, 0, vhi, '#ffa64d', 1.8, null, unitMul)
          } else if (L.k === 'pedals') {
            frame(L, 'brake / throttle', 0, 100, v => v + '%')
            line(L, P.s, P.it, P.seg, 0, 1, 'rgba(111,224,138,0.55)', 1.2, [4, 3])
            line(L, D.s, D.thr, D.seg, 0, 1, '#4fc3a1', 1.5)
            line(L, P.s, P.ib, P.seg, 0, 1, 'rgba(255,120,110,0.75)', 1.4, [4, 3])
            line(L, D.s, D.brk, D.seg, 0, 1, '#ff5a4a', 1.8)
            line(L, D.s, D.bp, D.seg, 0, 1, 'rgba(255,255,255,0.35)', 1)
          } else if (L.k === 'steer') {
            frame(L, 'steering', -1, 1, v => v)
            ctx.strokeStyle = 'rgba(255,255,255,0.12)'; ctx.lineWidth = dpr
            ctx.beginPath(); ctx.moveTo(left, (L.y0 + L.y1) / 2); ctx.lineTo(w - right, (L.y0 + L.y1) / 2); ctx.stroke()
            line(L, D.s, D.str, D.seg, -1, 1, '#b39ddb', 1.5)
          } else if (L.k === 'gear') {
            let ghi = 1
            if (D.gear) {
              const a = lowerBound(D.s, view.s0), b = Math.min(D.s.length - 1, lowerBound(D.s, view.s1))
              for (let i = a; i <= b; i++) ghi = Math.max(ghi, D.gear[i])
            }
            frame(L, 'gear', 0, ghi, v => v)
            line(L, D.s, D.gear, D.seg, 0, ghi, '#90a4ae', 1.5)
          }
        }
        // distance ticks
        ctx.fillStyle = '#5d666f'; ctx.font = (0.8 * fp) + 'px Roboto'
        const span = view.s1 - view.s0
        const step = [50, 100, 200, 500, 1000, 2000, 5000].find(s => span / s < 9) || 10000
        for (let s = Math.ceil(view.s0 / step) * step; s <= view.s1; s += step) {
          const x = X(s)
          ctx.fillRect(x, top, dpr, 3 * dpr)
          ctx.fillText(s >= 1000 ? (s / 1000).toFixed(step < 1000 ? 1 : 0) + ' km' : s + ' m', x + 2 * dpr, top + 1.0 * fp)
        }
      }

      function drawOverlay () {
        const m = prep(canv('over'))
        if (!m || !P || !chartGeom) return
        const { ctx, h, dpr } = m
        const g = chartGeom
        const X = s => g.left + (s - view.s0) / (view.s1 - view.s0) * (g.w - g.left - g.right)
        const x = X(cursorS)
        if (x >= g.left && x <= g.w - g.right) {
          ctx.strokeStyle = 'rgba(255,255,255,0.85)'; ctx.lineWidth = 1.2 * dpr
          ctx.beginPath(); ctx.moveTo(x, g.top); ctx.lineTo(x, h); ctx.stroke()
          ctx.fillStyle = '#fff'
          ctx.beginPath(); ctx.moveTo(x - 5 * dpr, g.top - 6 * dpr); ctx.lineTo(x + 5 * dpr, g.top - 6 * dpr); ctx.lineTo(x, g.top); ctx.fill()
        }
        updateReadout()
      }

      function deltaText (i) {
        const cmp = scope.curLap() ? compareSeries() : null
        const v = cmp ? cmp.d[i] : P.d[i]
        return (v >= 0 ? '+' : '') + v.toFixed(2) + (cmp ? ' s to ' + cmp.label2 : ' s')
      }
      function updateReadout () {
        if (!P) { scope.ro = null; return }
        const i = cursor, s = cursorS
        const D = T || P, j = T ? traceIdx(s) : i
        const val = (arr, k) => (arr && arr[k] != null ? arr[k] : 0)
        scope.ro = {
          km: s >= 1000 ? (s / 1000).toFixed(2) + ' km' : Math.round(s) + ' m',
          delta: deltaText(i),
          v: Math.round(val(D.v, j) * unitMul), iv: Math.round(P.iv[i] * unitMul),
          thr: Math.round(val(D.thr, j) * 100), brk: Math.round(val(D.brk, j) * 100), ib: Math.round(P.ib[i] * 100),
          str: val(D.str, j).toFixed(2), gear: val(D.gear, j), lat: Math.abs(val(D.lat, j)).toFixed(2),
        }
      }

      function redrawAll () { drawCharts(); drawOverlay(); drawMap() }

      // ---------- interaction ----------
      let drag = null, lastSeek = 0
      function sAtClientX (cx) {
        const c = canv('over'); const r = c.getBoundingClientRect()
        const g = chartGeom; if (!g) return view.s0
        const px = (cx - r.left) * g.dpr
        return view.s0 + (px - g.left) / (g.w - g.left - g.right) * (view.s1 - view.s0)
      }
      function placeCursor (s) {
        cursorS = Math.max(P.s[0], Math.min(P.s[P.s.length - 1], s))
        cursor = idxAtS(cursorS)
      }
      function setCursorS (s, seek) {
        placeCursor(Math.max(view.s0, Math.min(view.s1, s)))
        drawOverlay(); drawMap()
        scope.$evalAsync()
        if (seek && scope.st.mode === 'replay') {
          const now = Date.now()
          if (now - lastSeek > 90 || seek === 'final') { lastSeek = now; lua('replayAt(' + tAtS(cursorS).toFixed(3) + ')') }
        }
      }
      function onDown (e) {
        if (!P) return
        e.preventDefault()
        if (e.button === 2) drag = { pan: true, x: e.clientX, v: Object.assign({}, view) }
        else { drag = { scrub: true }; setCursorS(sAtClientX(e.clientX), true) }
        window.addEventListener('mousemove', onMove)
        window.addEventListener('mouseup', onUp)
      }
      function onMove (e) {
        if (!drag) return
        if (drag.scrub) setCursorS(sAtClientX(e.clientX), true)
        else if (drag.pan) {
          const c = canv('over'); const r = c.getBoundingClientRect(); const g = chartGeom
          const ds = -(e.clientX - drag.x) * g.dpr / (g.w - g.left - g.right) * (drag.v.s1 - drag.v.s0)
          setView(drag.v.s0 + ds, drag.v.s1 + ds)
        }
      }
      function onUp () {
        if (drag && drag.scrub) setCursorS(cursorS, 'final')
        drag = null
        window.removeEventListener('mousemove', onMove)
        window.removeEventListener('mouseup', onUp)
      }
      function setView (a, b) {
        const lo = P.s[0], hi = P.s[P.s.length - 1]
        const span = Math.max(40, Math.min(hi - lo, b - a))
        a = Math.max(lo, Math.min(hi - span, a))
        view = { s0: a, s1: a + span }
        drawCharts(); drawOverlay()
      }
      function onWheel (e) {
        if (!P) return
        e.preventDefault()
        const s = sAtClientX(e.clientX)
        const f = e.deltaY > 0 ? 1.25 : 0.8
        setView(s - (s - view.s0) * f, s + (view.s1 - s) * f)
      }
      function onDbl () { if (P) { const r = lapRange(); setView(P.s[r[0]], P.s[r[1]]) } }

      const over = canv('over')
      over.addEventListener('mousedown', onDown)
      over.addEventListener('wheel', onWheel, { passive: false })
      over.addEventListener('dblclick', onDbl)
      over.addEventListener('contextmenu', e => e.preventDefault())

      // the map: click to move the cursor to the nearest point of your line
      const mapC = canv('map')
      mapC.addEventListener('mousedown', function (e) {
        if (!P || !mapView) return
        const r = mapC.getBoundingClientRect(), dpr = window.devicePixelRatio || 1
        const w = r.width * dpr, h = r.height * dpr
        const bw = mapView.x1 - mapView.x0, bh = mapView.y1 - mapView.y0
        const sc = Math.min(w / bw, h / bh), ox = (w - bw * sc) / 2, oy = (h - bh * sc) / 2
        const wx = mapView.x0 + ((e.clientX - r.left) * dpr - ox) / sc
        const wy = mapView.y0 + (h - (e.clientY - r.top) * dpr - oy) / sc
        let best = 0, bd = Infinity
        for (let i = 0; i < P.s.length; i++) {
          const d = (P.x[i] - wx) ** 2 + (P.y[i] - wy) ** 2
          if (d < bd) { bd = d; best = i }
        }
        placeCursor(P.s[best])
        if (P.s[best] < view.s0 || P.s[best] > view.s1) {
          const span = view.s1 - view.s0
          setView(P.s[best] - span / 2, P.s[best] + span / 2)
        }
        drawOverlay(); drawMap(); scope.$evalAsync()
      })

      scope.select = function (id) {
        const c = scope.cornerById(id)
        if (!c || !P) return
        scope.selId = id
        clearStretch()
        const a = P.s[Math.max(0, c.i0 - 1)], b = P.s[Math.min(P.s.length - 1, c.i1 - 1)]
        const pad = Math.max(40, (b - a) * 0.4)
        setView(a - pad, b + pad)
        placeCursor(P.s[Math.max(0, c.iBrakeIdeal - 1)])
        mapView = boundsOf(c.i0 - 8, c.i1 + 4, 15)
        redrawAll()
        setTimeout(function () { const el = root.querySelector('.row.sel'); if (el && el.scrollIntoView) el.scrollIntoView({ block: 'nearest' }) }, 0)
      }
      scope.replay = function (id) { scope.select(id); lua('replayCorner(' + id + ')') }
      scope.replayHere = function () { if (P) lua('replayAt(' + tAtS(cursorS).toFixed(3) + ')') }
      scope.pauseReplay = function (p) { lua('setReplayPaused(' + (p ? 'true' : 'false') + ')') }
      scope.speed = function (x) { lua('setReplaySpeed(' + x + ')') }
      scope.exitReplay = function () { lua('exitReplay()') }
      scope.close = function () { lua('close()') }
      // in the replay: the next or previous turn within the same continuous playback
      scope.stepCorner = function (dir) { lua('replayStep(' + (dir > 0 ? 1 : -1) + ')') }
      // the whole drive from the selected turn (or the start)
      scope.replayDrive = function () {
        if (scope.selId) scope.replay(scope.selId)
        else if (P) lua('replayAt(' + P.t[0] + ')')
      }

      // ---------- race engineer ----------
      scope.eng = { online: false, q: '', history: [] }
      const luaStr = function (t) { return JSON.stringify(String(t).replace(/[^ -~]/g, ' ')) }
      let talking = false
      scope.talkDown = function (e) {
        if (e && e.button !== 0) return
        talking = true
        bngApi.engineLua('if coDriverEngineer then coDriverEngineer.talkDown("review") end')
      }
      scope.talkUp = function () {
        if (!talking) return
        talking = false
        bngApi.engineLua('if coDriverEngineer then coDriverEngineer.talkUp(' + (scope.selId || 'nil') + ', ' + (scope.lapSel || 'nil') + ') end')
      }
      scope.askTyped = function () {
        const q = (scope.eng.q || '').trim()
        if (!q) return
        scope.eng.q = ''
        bngApi.engineLua('if coDriverEngineer then coDriverEngineer.ask(' + luaStr(q) + ', "review", ' + (scope.selId || 'nil') + ', ' + (scope.lapSel || 'nil') + ') end')
      }
      scope.debrief = function () {
        const q = scope.curLap() ? 'Debrief this lap against my best lap: where did it lose time and what should I change?'
          : (scope.lapList().length ? 'Give me the debrief of my laps: how consistent was I, where did I lose the most time, and what should I do differently next run?'
            : 'Give me the debrief: where did I lose the most time and what should I do differently next run?')
        bngApi.engineLua('if coDriverEngineer then coDriverEngineer.ask(' + luaStr(q) + ', "review", nil, ' + (scope.lapSel || 'nil') + ') end')
      }
      scope.engOpt = function (key, value) {
        bngApi.engineLua('if coDriverEngineer then coDriverEngineer.setOption("' + key + '", ' + (value ? 'true' : 'false') + ') end')
      }
      scope.lastAnswer = function () {
        const h = scope.list(scope.eng.history)
        return h.length ? h[h.length - 1] : null
      }
      scope.engStatus = function () {
        const e = scope.eng
        if (!e.online) return 'engineer offline: run tools/engineer.bat'
        return 'engineer: ' + (e.llm ? 'Claude Haiku' : 'basic answers (no API key)') + (e.stt ? '' : ', no mic') +
          (e.sttEngine ? ' · hears with ' + (e.sttEngine === 'whisper' ? 'Whisper' : 'Windows') : '') +
          (e.ttsEngine ? ' · voice ' + ({ piper: 'Piper', kokoro: 'Kokoro' }[e.ttsEngine] || 'Windows') : '')
      }
      scope.$on('CoDriverEngineerState', function (e, st) {
        scope.$evalAsync(function () { Object.assign(scope.eng, st || {}, { q: scope.eng.q }) })
      })
      scope.$on('CoDriverEngineerHeard', function (e, h) {
        scope.$evalAsync(function () { scope.eng.heard = h && h.text })
      })
      bngApi.engineLua('if coDriverEngineer then coDriverEngineer.requestState() end')

      // ---------- game events ----------
      let wasMode = null, wasOpen = false
      scope.$on('CoDriverAnalysisData', function (e, d) { scope.$evalAsync(function () { setData(d) }) })
      // while open, the panel sits above the game's own HUD apps (0.40 added a minimap at the bottom left)
      let onTop = null
      function setOnTop (on) {
        if (on === onTop) return
        onTop = on
        let e = root.parentElement
        for (let i = 0; e && i < 10; i++, e = e.parentElement) {
          if (e.classList && e.classList.contains('overlay-item')) { e.style.zIndex = on ? '1000' : ''; return }
        }
      }
      scope.$on('CoDriverAnalysisState', function (e, st) {
        setOnTop(!!(st && st.open))
        scope.$evalAsync(function () {
          scope.st = st || { open: false }
          // the turn being replayed is the selected one (list, chart shading)
          if (st && st.mode === 'replay' && st.replay && st.replay.corner && st.replay.corner !== scope.selId) {
            scope.selId = st.replay.corner
            drawCharts()
          }
          if (st && st.mode === 'replay' && st.replay && st.replay.ready && P && !drag) {
            const s = sAtT(st.replay.t)
            if (Math.abs(s - cursorS) > 0.05) {
              placeCursor(s)
              if (s < view.s0 || s > view.s1) {
                const span = view.s1 - view.s0
                setView(s - span * 0.3, s + span * 0.7)
              }
              drawOverlay(); drawMap()
            }
          }
          if (st && (st.mode !== wasMode || st.open !== wasOpen)) {
            wasMode = st.mode; wasOpen = st.open
            setTimeout(redrawAll, 40)
          }
        })
      })
      const ro = new ResizeObserver(function () { if (scope.st.open) redrawAll() })
      ro.observe(root)
      scope.$on('$destroy', function () { ro.disconnect() })

      bngApi.engineLua('if coDriverAnalysis then coDriverAnalysis.requestState() end')
    }
  }
}])
