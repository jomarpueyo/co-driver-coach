angular.module('beamng.apps')
.directive('coDriverDebrief', [function () {
  return {
    template: `
<div class="cdd" ng-show="s && !s.hidden">
  <style>
    .cdd { zoom:var(--ui-scale, 1); width:100%; height:auto; max-height:100%; box-sizing:border-box; padding:12px 14px; background:rgba(15,17,20,0.88);
           border-radius:10px; color:#e8e8e8; font-family:'Roboto', sans-serif; font-size:13px; overflow-y:auto; }
    .cdd .head { display:flex; align-items:center; gap:12px; }
    .cdd .title { font-size:11px; font-weight:700; letter-spacing:1.5px; color:#9aa3ad; }
    .cdd .big { font-size:40px; font-weight:800; line-height:1; min-width:58px; text-align:center; }
    .cdd .stats { color:#aab2bb; font-size:12px; margin-top:3px; }
    .cdd .prev { color:#7d868f; font-size:11px; margin-top:2px; }
    .cdd .up { color:#8fd694; } .cdd .down { color:#ff6b5e; }
    .cdd .close { margin-left:auto; align-self:flex-start; cursor:pointer; padding:2px 8px; border-radius:4px; background:#2b3038; color:#c8ced6; font-size:11px; text-transform:uppercase; }
    .cdd table { width:100%; border-collapse:collapse; margin-top:6px; }
    .cdd td { padding:3px 4px; vertical-align:middle; }
    .cdd .aname { width:34%; color:#c8ced6; }
    .cdd .alet { width:34px; font-weight:800; font-size:15px; text-align:center; }
    .cdd .bar { width:60px; height:5px; background:#2b3038; border-radius:3px; overflow:hidden; }
    .cdd .bar div { height:100%; border-radius:3px; }
    .cdd .adet { color:#8a939c; font-size:11px; }
    .cdd tr.na td { opacity:0.45; }
    .cdd tr.focus td { background:rgba(255,255,255,0.05); }
    .cdd .card { margin-top:10px; padding:10px 12px; border-radius:8px; background:rgba(90,59,140,0.22); border-left:3px solid #8e6bd1; }
    .cdd .card h3 { margin:0 0 4px 0; font-size:13px; font-weight:700; letter-spacing:0.5px; }
    .cdd .card .why { color:#c8ced6; font-size:12px; }
    .cdd .card ul { margin:6px 0 0 0; padding-left:18px; }
    .cdd .card li { margin:3px 0; }
    .cdd .worst { color:#ffb870; font-size:12px; margin-top:4px; }
    .cdd .mind { margin-top:10px; padding:8px 10px; border-radius:6px; background:rgba(255,255,255,0.06); }
    .cdd .mind .mt { font-weight:800; font-size:14px; color:#fff; }
    .cdd .mind .mx { color:#c8ced6; font-size:12px; margin-top:2px; font-style:italic; }
    .cdd .msg { color:#c8ced6; margin-top:10px; }
    .cdd .calib { color:#7d868f; font-size:11px; }
    .cdd .stagel { color:#9ec3ff; font-size:12px; font-weight:700; margin-top:2px; }
    .cdd .cols { display:flex; flex-wrap:wrap; gap:16px; margin-top:8px; }
    .cdd .colL { flex:1 1 430px; min-width:0; }
    .cdd .colR { flex:1 1 300px; min-width:0; }
    .cdd .colR .path { margin-top:0; }
    .cdd .path { margin-top:10px; padding:8px 10px; border-radius:8px; background:rgba(58,123,213,0.16); border-left:3px solid #3a7bd5; }
    .cdd .path .pt { font-size:11px; font-weight:700; letter-spacing:1px; color:#9ec3ff; margin-bottom:3px; }
    .cdd .path .step { cursor:pointer; padding:2px 0; }
    .cdd .path .step:hover { color:#fff; }
    .cdd .path .gain { color:#8fd694; font-size:11px; margin-left:4px; }
    .cdd .path .more { color:#7d868f; font-size:11px; margin-left:4px; }
    .cdd .path .pnote { color:#7d868f; font-size:11px; margin-top:2px; }
    .cdd tr.arow { cursor:pointer; }
    .cdd tr.arow:hover td { background:rgba(255,255,255,0.04); }
    .cdd tr.open td { background:rgba(255,255,255,0.06); }
    .cdd .chev { width:12px; color:#7d868f; font-size:11px; }
    .cdd tr.drow td { padding:2px 4px 10px 4px; background:rgba(255,255,255,0.03); }
    .cdd .dmeasure { color:#9aa3ad; font-size:11px; line-height:1.4; }
    .cdd .dstat { color:#c8ced6; font-size:12px; margin-top:4px; }
    .cdd .dnext { color:#e8e8e8; font-size:12px; margin-top:6px; }
    .cdd .dtip { color:#ffb870; font-size:12px; margin-top:4px; }
    .cdd .hintline { color:#5d666f; font-size:10px; margin-top:4px; }
    .cdd .fnext { color:#e8e8e8; font-size:12px; margin-top:6px; }
    .cdd .session { display:flex; align-items:center; gap:10px; margin-top:10px; padding:8px 10px; border-radius:8px; background:rgba(58,123,213,0.14); }
    .cdd .session .rec { color:#ff5a4a; font-weight:800; font-size:11px; letter-spacing:1px; }
    .cdd .session .stxt { color:#c8ced6; font-size:12px; flex:1; }
    .cdd .sbtn { cursor:pointer; padding:5px 12px; border-radius:5px; background:#2b3038; color:#e8e8e8; font-size:12px; font-weight:600; white-space:nowrap; }
    .cdd .sbtn:hover { background:#3a414c; }
    .cdd .sbtn.prim { background:#3a7bd5; color:#fff; }
    .cdd .sbtn.prim:hover { background:#4a8be5; }
    .cdd .gA { color:#8fd694; } .cdd .gB { color:#c5e17a; } .cdd .gC { color:#ffd166; } .cdd .gD { color:#ff9f43; } .cdd .gF { color:#ff6b5e; }
  </style>

  <div class="head">
    <div class="big" ng-if="s.overall" ng-class="g(s.overall.letter)">{{ s.overall.letter }}</div>
    <div>
      <div class="title">END OF DRIVE</div>
      <div class="stats" ng-if="s.time">{{ s.time }} · {{ s.dist }} · avg {{ s.avgSpeed }} / max {{ s.maxSpeed }} {{ s.unit }} · {{ s.corners }} corners</div>
      <div class="stagel" ng-if="s.stage">🏁 {{ s.stage }}</div>
      <div class="prev" ng-if="s.previous">
        Last drive {{ s.previous.letter }}
        <span ng-class="{up: s.previous.delta > 0, down: s.previous.delta < 0}">({{ s.previous.delta > 0 ? '+' : '' }}{{ s.previous.delta }} pts)</span>
      </div>
    </div>
    <span class="close" ng-click="dismiss()">close</span>
  </div>
  <div class="session" ng-if="s.analysis">
    <span class="rec">● REC</span>
    <span class="stxt">Your telemetry and replay are still recording.</span>
    <span class="sbtn" ng-click="keepRecording()">Keep recording</span>
    <span class="sbtn prim" ng-click="reviewAnalysis()">Review analysis ▸</span>
  </div>

  <div class="msg" ng-if="s.tooShort">{{ s.message }}</div>
  <div class="cols" ng-if="!s.tooShort">
   <div class="colL">
  <div class="calib" ng-if="s.calib && !s.tooShort">{{ s.calib }}</div>
  <table ng-if="s.aspects && !s.tooShort">
    <tr ng-repeat-start="a in s.aspects" class="arow" ng-click="toggle(a.key)"
        ng-class="{na: !a.score && a.score !== 0, focus: s.focus && a.key == s.focus.key, open: open[a.key]}">
      <td class="chev">{{ open[a.key] ? '▾' : '▸' }}</td>
      <td class="aname">{{ a.name }}</td>
      <td class="alet" ng-class="g(a.letter)">{{ a.letter || '–' }}</td>
      <td><div class="bar"><div ng-style="{width: (a.score || 0) + '%', background: color(a.letter)}"></div></div></td>
      <td class="adet">{{ a.detail }}</td>
    </tr>
    <tr ng-repeat-end ng-if="open[a.key]" class="drow">
      <td></td>
      <td colspan="4">
        <div class="dmeasure">{{ a.measure }}</div>
        <div class="dstat" ng-repeat="t in list(a.stats)">{{ t }}</div>
        <div class="dnext" ng-if="a.next && a.next.how">
          To reach <b ng-class="g(a.next.letter)">{{ a.next.letter }}</b>: {{ a.next.how }}.
        </div>
        <div class="dnext" ng-if="a.score >= 97">Top grade. Keep it there.</div>
        <div class="dtip" ng-if="a.tip">Try: {{ a.tip }}</div>
      </td>
    </tr>
  </table>
  <div class="hintline" ng-if="s.aspects && !s.tooShort">Click a row for how it's measured and what gets you the next grade.</div>
   </div>
   <div class="colR">
  <div class="path" ng-if="s.path && list(s.path.steps).length && !s.tooShort">
    <div class="pt">TO GET <span ng-class="g(s.path.letter)">{{ s.path.letter }}</span> OVERALL</div>
    <div class="step" ng-repeat="st in list(s.path.steps)" ng-click="toggle(st.key, true)">
      Raise <b>{{ st.name }}</b> <span ng-class="g(st.from)">{{ st.from }}</span> → <span ng-class="g(st.to)">{{ st.to }}</span>
      <span class="gain">+{{ st.gain }} pts</span> <span class="more">how ›</span>
    </div>
    <div class="pnote" ng-if="!s.path.reached">…and keep going: that gets you most of the way there.</div>
  </div>
  <div class="card" ng-if="s.focus">
    <h3>FOCUS: {{ s.focus.name }} <span ng-class="g(s.focus.letter)">{{ s.focus.letter }}</span>
      <span class="prev" ng-if="s.previous && s.previous.focusLetter"> · last drive {{ s.previous.focusLetter }}</span></h3>
    <div class="why">{{ s.focus.detail }}</div>
    <div class="worst" ng-repeat="w in list(s.focus.worst)">▸ {{ w }}</div>
    <div class="fnext" ng-if="s.focus.next && s.focus.next.how">
      To reach <b ng-class="g(s.focus.next.letter)">{{ s.focus.next.letter }}</b>: {{ s.focus.next.how }}.
    </div>
    <ul>
      <li ng-repeat="t in list(s.focus.tips)">{{ t }}</li>
    </ul>
    <div class="mind" ng-if="s.focus.mentality">
      <div class="mt">"{{ s.focus.mentality.title }}"</div>
      <div class="mx">{{ s.focus.mentality.text }}</div>
    </div>
  </div>
   </div>
  </div>
</div>`,
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element, attrs) {
      scope.s = null
      scope.open = {}

      // While hidden, let clicks pass through this panel's (invisible) container to whatever is underneath.
      function setClickable (on) {
        let e = element[0].parentElement
        for (let i = 0; e && i < 8; i++, e = e.parentElement) {
          e.style.pointerEvents = on ? '' : 'none'
          if (e.classList && e.classList.contains('overlay-item')) break
        }
      }
      setTimeout(() => setClickable(false), 0)

      // empty Lua tables arrive as {} rather than []
      scope.list = function (x) { return Array.isArray(x) ? x : [] }
      scope.toggle = function (key, only) {
        if (only) scope.open = {}
        scope.open[key] = only ? true : !scope.open[key]
      }
      scope.g = function (l) { return l ? 'g' + l.charAt(0) : '' }
      scope.color = function (l) {
        return { A: '#8fd694', B: '#c5e17a', C: '#ffd166', D: '#ff9f43', F: '#ff6b5e' }[l ? l.charAt(0) : ''] || '#59616b'
      }
      scope.dismiss = function () { bngApi.engineLua('if coDriverCoach then coDriverCoach.dismissSummary() end') }
      scope.keepRecording = function () { bngApi.engineLua('if coDriverAnalysis then coDriverAnalysis.keepRecording() end') }
      scope.reviewAnalysis = function () { bngApi.engineLua('if coDriverAnalysis then coDriverAnalysis.review() end') }

      scope.$on('CoDriverCoachSummary', function (event, data) {
        scope.$evalAsync(function () {
          if (!scope.s || scope.s.time !== data.time || scope.s.dist !== data.dist) scope.open = {}
          scope.s = data
          setClickable(!!(data && !data.hidden))
        })
      })

      bngApi.engineLua('if coDriverCoach then coDriverCoach.requestState() end')
    }
  }
}])
