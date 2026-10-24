angular.module('beamng.apps')
.directive('coDriverScenarios', [function () {
  return {
    template: `
<div class="cds" ng-show="m && m.open">
  <style>
    .cds { zoom:var(--ui-scale, 1); width:100%; height:auto; max-height:100%; box-sizing:border-box; padding:12px 14px; background:rgba(15,17,20,0.92);
           border-radius:10px; color:#e8e8e8; font-family:'Roboto', sans-serif; font-size:13px; overflow-y:auto; }
    .cds .head { display:flex; align-items:center; gap:10px; }
    .cds .title { font-size:11px; font-weight:700; letter-spacing:1.5px; color:#9aa3ad; flex:1; }
    .cds .btn { cursor:pointer; padding:3px 9px; border-radius:5px; background:#2b3038; color:#c8ced6; font-size:11px; text-transform:uppercase; }
    .cds .btn:hover { background:#39404a; color:#fff; }
    .cds .btn.on { background:#2f6f4f; color:#fff; }
    .cds .btn.go { background:#3a7bd5; color:#fff; }
    .cds .opts { display:flex; flex-wrap:wrap; align-items:center; gap:6px; margin-top:10px; padding:8px 10px; border-radius:8px; background:rgba(255,255,255,0.04); }
    .cds .lbl { color:#7d868f; font-size:11px; margin-right:2px; }
    .cds .sep { width:14px; }
    .cds .note { color:#7d868f; font-size:11px; margin-top:6px; }
    .cds .grid { display:grid; grid-template-columns:repeat(auto-fill, minmax(230px, 1fr)); gap:8px; margin-top:10px; }
    .cds .card { cursor:pointer; padding:9px 11px; border-radius:8px; background:rgba(255,255,255,0.05); border:1px solid transparent; }
    .cds .card:hover { background:rgba(58,123,213,0.18); border-color:#3a7bd5; }
    .cds .card.last { border-color:#5a3b8c; }
    .cds .card.here .map { color:#8fd694; }
    .cds .ct { font-weight:700; font-size:14px; }
    .cds .map { color:#9aa3ad; font-size:11px; margin-top:1px; }
    .cds .car { color:#c8ced6; font-size:11px; margin-top:4px; }
    .cds .desc { color:#8a939c; font-size:11px; margin-top:3px; line-height:1.35; }
    .cds .surf { display:inline-block; margin-left:6px; padding:0 5px; border-radius:3px; font-size:9px; text-transform:uppercase; background:#2b3038; color:#c8ced6; }
    .cds .surf.gravel { background:#5c4326; color:#ffd8a8; }
    .cds .loading { margin-top:10px; padding:8px 10px; border-radius:6px; background:rgba(58,123,213,0.2); color:#9ec3ff; font-weight:600; }
  </style>

  <div class="head">
    <span class="title">CO-DRIVER SCENARIOS</span>
    <span class="btn" ng-if="m.last" ng-click="restart()" title="Load the last scenario again with the same options">restart last</span>
    <span class="btn" ng-if="m.stage" ng-click="cmd('coDriverCoach.cancelStage()')">cancel stage</span>
    <span class="btn" ng-click="cmd('coDriverCoach.closeMenu()')">close</span>
  </div>

  <div class="opts">
    <span class="lbl">Car:</span>
    <span class="btn" ng-class="{on: !ownCar}" ng-click="ownCar = false">scenario car</span>
    <span class="btn" ng-class="{on: ownCar}" ng-click="ownCar = true">my current car</span>
    <span class="sep"></span>
    <span class="lbl">Stage:</span>
    <span class="btn" ng-repeat="k in [0, 2, 4, 6]" ng-class="{on: stageKm == k}" ng-click="setStage(k)">{{ k ? k + ' km' : 'free drive' }}</span>
  </div>
  <div class="note" ng-if="stageKm > 0">Stage mode: the GPS sets a finish {{ stageKm }} km away by road. Cross it and the debrief opens with your stage time.</div>
  <div class="note" ng-if="stageKm == 0">Free drive: end the drive with END on the coach strip, or park for 20 seconds.</div>

  <div class="loading" ng-if="m.loading">Loading {{ m.loading }}…</div>

  <div class="grid">
    <div class="card" ng-repeat="s in list(m.scenarios)" ng-click="load(s.id)"
         ng-class="{last: s.id == m.last, here: levelOf(s) == m.level}"
         title="{{ levelOf(s) == m.level ? 'Same map: no reload, just swaps the car and moves you' : 'Loads ' + s.map }}">
      <div class="ct">{{ s.title }} <span class="surf" ng-class="s.surface">{{ s.surface }}</span></div>
      <div class="map">{{ s.map }}<span ng-if="levelOf(s) == m.level"> · you are here</span></div>
      <div class="car">{{ ownCar ? 'Your current car' : s.car }}</div>
      <div class="desc">{{ s.desc }}</div>
    </div>
  </div>
</div>`,
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element, attrs) {
      scope.m = null
      scope.ownCar = false
      scope.stageKm = 0

      // While hidden, let clicks pass through this panel's (invisible) container to whatever is underneath.
      function setClickable (on) {
        let e = element[0].parentElement
        for (let i = 0; e && i < 8; i++, e = e.parentElement) {
          e.style.pointerEvents = on ? '' : 'none'
          if (e.classList && e.classList.contains('overlay-item')) break
        }
      }
      setTimeout(() => setClickable(false), 0)

      // the scenario's level id, as getCurrentLevelIdentifier() reports it (lower case)
      const levels = {
        'Italy': 'italy', 'Utah': 'utah', 'West Coast USA': 'west_coast_usa', 'East Coast USA': 'east_coast_usa',
        'Jungle Rock Island': 'jungle_rock_island', 'Johnson Valley': 'johnson_valley',
        'Automation Test Track': 'automation_test_track', 'Hirochi Raceway': 'hirochi_raceway',
      }
      scope.levelOf = function (s) { return levels[s.map] }
      // empty Lua tables arrive as {} rather than []
      scope.list = function (x) { return Array.isArray(x) ? x : [] }
      scope.cmd = function (lua) { bngApi.engineLua(lua) }
      scope.setStage = function (k) { scope.stageKm = k }
      scope.load = function (id) {
        if (scope.m && scope.m.loading) return
        bngApi.engineLua('coDriverCoach.loadScenario(' + JSON.stringify(String(id).replace(/[^ -~]/g, ' ')) + ', ' + (scope.ownCar ? 'true' : 'false') + ', ' + Number(scope.stageKm) + ')')
      }
      scope.restart = function () { bngApi.engineLua('coDriverCoach.restartScenario()') }

      scope.$on('CoDriverCoachMenu', function (event, data) {
        scope.$evalAsync(function () {
          const opening = data.open && !(scope.m && scope.m.open)
          scope.m = data
          setClickable(!!data.open)
          if (opening) { // start from the options used last time
            scope.ownCar = !!data.ownCar
            scope.stageKm = Number(data.stageKm) || 0
          }
        })
      })

      bngApi.engineLua('if coDriverCoach then coDriverCoach.requestState() end')
    }
  }
}])
