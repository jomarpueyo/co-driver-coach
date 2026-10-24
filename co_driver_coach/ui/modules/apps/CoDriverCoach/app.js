angular.module('beamng.apps')
.directive('coDriverCoach', [function () {
  return {
    template: `
<div class="cdc">
  <style>
    .cdc { zoom:var(--ui-scale, 1); width:100%; height:100%; box-sizing:border-box; padding:6px 12px 6px 12px; background:rgba(15,17,20,0.84);
           border-radius:10px; color:#e8e8e8; font-family:'Roboto', sans-serif; font-size:13px; overflow:hidden;
           display:flex; flex-direction:column; }
    .cdc .top { display:flex; align-items:center; gap:5px; height:16px; }
    .cdc .title { font-weight:700; letter-spacing:1.5px; font-size:10px; color:#a7b0ba; flex:1; }
    .cdc .btn { cursor:pointer; padding:0 6px; line-height:15px; border-radius:4px; background:#2b3038; color:#aab2bb; font-size:9px; text-transform:uppercase; }
    .cdc .btn.on { background:#2f6f4f; color:#fff; }
    .cdc .btn.end { background:#5a3b8c; color:#fff; }
    .cdc .btn.rec { background:#2b3038; color:#d6dbe1; }
    .cdc .btn.menu { background:#3a7bd5; color:#fff; }
    .cdc .slot.stage { background:rgba(58,123,213,0.2); color:#9ec3ff; }
    .cdc .shift { font-weight:800; padding:0 6px; line-height:15px; border-radius:4px; background:#3a7bd5; color:#fff; font-size:10px; }
    .cdc .main { display:flex; align-items:baseline; gap:10px; margin-top:3px; height:30px; }
    .cdc .arrow { font-size:20px; width:20px; text-align:center; }
    .cdc .note { font-size:24px; font-weight:700; flex:1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .cdc .dist { font-size:15px; color:#e8e8e8; font-weight:600; }
    .cdc .spd { font-size:12px; color:#9aa3ad; min-width:62px; text-align:right; }
    .cdc .next { display:flex; gap:14px; color:#aab2bb; font-size:12px; height:17px; white-space:nowrap; overflow:hidden; }
    .cdc .next .lbl { color:#8a939c; }
    .cdc .slot { margin-top:auto; height:22px; border-radius:5px; display:flex; align-items:center; justify-content:center;
                 font-size:12px; font-weight:700; padding:0 8px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .cdc .slot.footer { justify-content:flex-start; font-weight:400; color:#9aa3ad; font-size:11px; padding:0; }
    .cdc .slot.soon { background:rgba(255,209,102,0.16); color:#ffd166; }
    .cdc .slot.brake { background:#e67e22; color:#111; }
    .cdc .slot.late { background:#e74c3c; color:#fff; }
    .cdc .slot.hint { background:rgba(255,159,67,0.22); color:#ffb870; }
    .cdc .slot.hint2 { background:rgba(231,76,60,0.45); color:#fff; }
    .cdc .slot.lap { background:rgba(46,204,113,0.15); color:#8be3b0; font-variant-numeric:tabular-nums; }
    .cdc .slot.lap .ahead { color:#7ee2a8; } .cdc .slot.lap .behind { color:#ffb870; } .cdc .slot.lap .bad { color:#ff8a80; }
    .cdc .g0, .cdc .g1 { color:#ff6b5e; } .cdc .g2 { color:#ff9f43; } .cdc .g3, .cdc .g4 { color:#ffd166; }
    .cdc .g5, .cdc .g6 { color:#8fd694; } .cdc .g7 { color:#7cc4ff; }
  </style>

  <div class="top">
    <span class="title">CO-DRIVER</span>
    <span class="shift" ng-if="d.shift == 'up'">SHIFT ▲</span>
    <span class="shift" ng-if="d.shift == 'down'">SHIFT ▼</span>
    <span class="btn" ng-class="{on: d.enabled}" ng-click="cmd('coDriverCoach.toggle()')">{{ d.enabled ? 'on' : 'off' }}</span>
    <span class="btn" ng-class="{on: d.voice && d.hasVoice}" ng-click="cmd('coDriverCoach.toggleVoice()')">voice</span>
    <span class="btn" ng-click="cmd('coDriverCoach.cycleSurface()')">{{ d.surface || 'tarmac' }}</span>
    <span class="btn" ng-click="cmd('coDriverCoach.toggleStyle()')">{{ d.style == 'words' ? 'words' : '1-6' }}</span>
    <span class="btn end" ng-if="d.drive" ng-click="cmd('coDriverCoach.endDrive()')" title="Finish this drive and show the summary">end</span>
    <span class="btn rec" ng-click="cmd('if coDriverAnalysis then coDriverAnalysis.open() end')" title="Drive analysis: your line and inputs against a better line, with corner replays">{{ d.recording ? '● analysis' : 'analysis' }}</span>
    <span class="btn menu" ng-click="cmd('coDriverCoach.toggleMenu()')" title="Practice scenarios: map, car and an optional GPS stage">scenarios</span>
    <span class="btn" ng-click="cmd('if coDriverAnalysis then coDriverAnalysis.openSettings() end')" title="Settings: calls, voice, braking aid, engineer, recording and laps">⚙</span>
  </div>

  <div class="main" ng-if="!d || !d.enabled">
    <span class="note" style="font-size:15px; color:#7d868f">{{ !d ? 'Waiting for Co-Driver Coach…' : 'Coach is off' }}</span>
  </div>

  <div class="main" ng-if="d.enabled && !d.onRoad">
    <span class="note" style="font-size:15px; color:#7d868f">No road under the car</span>
  </div>
  <div class="main" ng-if="d.enabled && d.onRoad && list(d.notes).length == 0">
    <span class="note g6">Straight</span>
  </div>
  <div class="main" ng-if="d.enabled && list(d.notes).length > 0">
    <span class="arrow" ng-class="'g' + d.notes[0].grade">{{ glyph(d.notes[0]) }}</span>
    <span class="note" ng-class="'g' + d.notes[0].grade">{{ d.notes[0].text }}</span>
    <span class="dist">{{ d.notes[0].dist }} m</span>
    <span class="spd" ng-if="d.notes[0].speed">≤ {{ d.notes[0].speed }} {{ d.unit }}</span>
  </div>

  <div class="next" ng-if="d.enabled">
    <span ng-if="list(d.notes).length > 1" class="lbl">then</span>
    <span ng-repeat="n in list(d.notes).slice(1)">
      <span ng-class="'g' + n.grade">{{ glyph(n) }} {{ n.text }}</span> {{ n.dist }} m<span ng-if="n.speed"> · ≤{{ n.speed }}</span>
    </span>
  </div>

  <div ng-if="d.enabled" class="slot" ng-class="slotClass()" ng-style="barStyle()">
    <span ng-if="d.hint">{{ d.hint }}</span>
    <span ng-if="!d.hint && d.brake.state == 'soon'">Brake soon → {{ d.brake.target }} {{ d.unit }}</span>
    <span ng-if="!d.hint && d.brake.state == 'brake'">BRAKE → {{ d.brake.target }} {{ d.unit }}</span>
    <span ng-if="!d.hint && d.brake.state == 'late'">TOO FAST → {{ d.brake.target }} {{ d.unit }}</span>
    <span ng-if="slotClass() == 'lap' && showLast()">Lap {{ laps.last.n }}: {{ fmtLap(laps.last.time, 3) }}<span ng-if="laps.last.best"> · best lap</span><span ng-if="laps.last.valid && laps.last.deltaBest != null" ng-class="laps.last.deltaBest <= 0 ? 'ahead' : 'behind'"> · {{ fmtDelta(laps.last.deltaBest) }}</span><span ng-if="!laps.last.valid" class="bad"> · invalid: {{ laps.last.reason }}</span></span>
    <span ng-if="slotClass() == 'lap' && !showLast()">Lap {{ laps.n }} · {{ fmtLap(laps.time, 1) }}<span ng-if="laps.valid && laps.delta != null" ng-class="laps.delta <= 0 ? 'ahead' : 'behind'"> · {{ fmtDelta(laps.delta) }}</span><span ng-if="laps.sector" ng-class="laps.sector.delta <= 0 ? 'ahead' : 'behind'"> · S{{ laps.sector.k }} {{ fmtDelta(laps.sector.delta) }}</span><span ng-if="laps.valid && laps.best && !laps.sector"> · best {{ fmtLap(laps.best, 3) }}</span><span ng-if="!laps.valid" class="bad"> · invalid: {{ laps.reason }}</span></span>
    <span ng-if="slotClass() == 'stage' && d.loading">Loading {{ d.loading }}…</span>
    <span ng-if="slotClass() == 'stage' && !d.loading">Stage {{ d.stage.km }} km · {{ fmtDist(d.stage.left) }} to the finish<span ng-if="d.drive"> · {{ fmtTime(d.drive.time) }}</span></span>
    <span ng-if="slotClass() == 'footer'">
      <span ng-if="d.drive">Drive {{ fmtTime(d.drive.time) }} · {{ d.drive.corners }} corners · </span>
      {{ d.usingRoute ? 'GPS route' : 'Following road' }}<span ng-if="d.lastCall"> · last: {{ d.lastCall }}</span><span ng-if="!d.hasVoice"> · no voice clips</span>
    </span>
  </div>
</div>`,
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element, attrs) {
      scope.d = null

      scope.cmd = function (lua) { bngApi.engineLua(lua) }

      // hide the whole strip (and stop it catching clicks) while the drive analysis is open
      function setHidden (hidden) {
        let e = element[0]
        for (let i = 0; e && i < 10; i++, e = e.parentElement) {
          if (e.classList && e.classList.contains('overlay-item')) { e.style.visibility = hidden ? 'hidden' : ''; return }
        }
        element[0].style.visibility = hidden ? 'hidden' : ''
      }
      scope.$on('CoDriverAnalysisState', function (event, st) { setHidden(!!(st && st.open)) })
      // empty Lua tables arrive as {} rather than []
      scope.list = function (x) { return Array.isArray(x) ? x : [] }

      scope.fmtTime = function (s) {
        return Math.floor(s / 60) + ':' + ('0' + Math.floor(s % 60)).slice(-2)
      }

      scope.glyph = function (n) {
        if (n.kind == 'crest') return '⌒'
        return n.sign > 0 ? '◀' : '▶'
      }

      scope.fmtDist = function (m) {
        return m >= 1000 ? (m / 1000).toFixed(1) + ' km' : Math.round(m) + ' m'
      }

      // lap timing (coDriverLaps): the running lap, or for 5 s after a lap its result
      scope.laps = null
      scope.showLast = function () { const l = scope.laps; return !!(l && l.last && (l.lastAge < 5 || !l.active)) }
      scope.fmtLap = function (s, dec) {
        const m = Math.floor(s / 60), r = (s - m * 60).toFixed(dec)
        return m + ':' + (r < 10 ? '0' : '') + r
      }
      scope.fmtDelta = function (x) { return (x <= 0 ? '−' : '+') + Math.abs(x).toFixed(2) }
      scope.$on('CoDriverLaps', function (event, data) {
        scope.$evalAsync(function () { scope.laps = data && (data.active || data.last) ? data : null })
      })

      // one status line: slide hint beats brake cue beats the lap timer beats stage/loading beats the footer
      scope.slotClass = function () {
        const d = scope.d
        if (!d) return 'footer'
        if (d.hint) return d.hintLevel == 2 ? 'hint2' : 'hint'
        if (d.brake && d.brake.state && d.brake.state != 'none') return d.brake.state
        if (scope.laps) return 'lap'
        if (d.loading || d.stage) return 'stage'
        return 'footer'
      }

      // the braking bar: fills up to the brake point while a brake cue is showing
      scope.barStyle = function () {
        const d = scope.d, c = scope.slotClass()
        if (!(d && d.brake && d.brake.fill != null && (c == 'soon' || c == 'brake'))) return {}
        const f = d.brake.fill + '%'
        return c == 'soon'
          ? { background: 'linear-gradient(90deg, rgba(255,209,102,0.55) ' + f + ', rgba(255,209,102,0.12) ' + f + ')', color: '#ffe2a0' }
          : { background: 'linear-gradient(90deg, #e67e22 ' + f + ', rgba(230,126,34,0.4) ' + f + ')' }
      }

      scope.$on('CoDriverCoachUpdate', function (event, data) {
        scope.$evalAsync(function () { scope.d = data })
      })

      bngApi.engineLua('if coDriverCoach then coDriverCoach.requestState() end')
    }
  }
}])
