angular.module('beamng.apps')
.directive('coDriverMap', [function () {
  return {
    template: `
<div style="zoom:var(--ui-scale, 1); width:100%; height:100%; box-sizing:border-box; background:rgba(15,17,20,0.84); border-radius:8px; overflow:hidden; position:relative; font-family:'Roboto', sans-serif;">
  <svg class="cdm-svg" style="width:100%; height:100%; display:block;"></svg>
  <div class="cdm-msg" style="position:absolute; left:0; right:0; top:45%; text-align:center; color:#7d868f; font-size:12px;">Waiting for Co-Driver Coach…</div>
</div>`,
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element, attrs) {
      const svg = element[0].querySelector('.cdm-svg')
      const msg = element[0].querySelector('.cdm-msg')

      // same severity colours as the Co-Driver Coach panel
      const gradeColor = g => {
        if (g === undefined || g === null) return '#9aa3ad'
        if (g <= 1) return '#ff6b5e'
        if (g == 2) return '#ff9f43'
        if (g <= 4) return '#ffd166'
        if (g <= 6) return '#8fd694'
        return '#7cc4ff'
      }

      function draw (d) {
        const view = d && d.enabled ? d.view : null
        if (!view || !view.pts || view.pts.length < 4) {
          svg.innerHTML = ''
          msg.style.display = 'block'
          msg.textContent = !d ? 'Waiting for Co-Driver Coach…' : (!d.enabled ? 'Coach is off' : 'No road under the car')
          return
        }
        msg.style.display = 'none'

        const W = svg.clientWidth || 200, H = svg.clientHeight || 260
        const cx = W / 2, cy = H - 22
        const range = Math.min(Math.max(view.speed * 6 + 80, 120), 350) // metres shown ahead, zooms out with speed
        const P = view.pts
        // fit the visible stretch sideways too, but never zoom out more than 3x
        let maxX = 1
        for (let i = 0; i < P.length; i += 2) if (P[i + 1] <= range) maxX = Math.max(maxX, Math.abs(P[i]))
        const sV = (H - 40) / range
        const s = Math.max(Math.min(sV, (W / 2 - 14) / maxX), sV / 3)
        const px = (x, y) => (cx + x * s).toFixed(1) + ',' + (cy - y * s).toFixed(1)
        const line = (i0, i1) => {
          const out = []
          for (let i = i0; i <= i1; i++) out.push(px(P[2 * i - 2], P[2 * i - 1]))
          return out.join(' ')
        }
        const n = P.length / 2
        let h = ''

        // distance ticks
        for (const m of [50, 100, 200, 300, 400, 600]) {
          if (m * s > H - 30) break
          const y = (cy - m * s).toFixed(1)
          h += `<line x1="6" x2="${W - 6}" y1="${y}" y2="${y}" stroke="rgba(255,255,255,0.07)" stroke-width="1"/>`
          h += `<text x="8" y="${y - 3}" fill="rgba(255,255,255,0.55)" font-size="10">${m} m</text>`
        }

        // the road the coach is reading
        h += `<polyline points="${line(1, n)}" fill="none" stroke="#59616b" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>`

        // corners and crests, coloured by severity; skip a label that would land on top of another
        // (an empty Lua table arrives as {} rather than [])
        const placed = []
        for (const m of Array.isArray(view.marks) ? view.marks : []) {
          const col = gradeColor(m.grade)
          if (m.kind == 'crest') {
            const [x, y] = px(m.x, m.y).split(',')
            h += `<circle cx="${x}" cy="${y}" r="4" fill="none" stroke="${col}" stroke-width="2"/>`
          } else if (m.i1 > m.i0) {
            h += `<polyline points="${line(m.i0, m.i1)}" fill="none" stroke="${col}" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>`
          }
          if (m.label) {
            const [x, y] = px(m.x, m.y).split(',')
            if (placed.some(p => Math.abs(p[0] - x) < 26 && Math.abs(p[1] - y) < 13)) continue
            placed.push([+x, +y])
            h += `<text x="${+x + 7}" y="${+y + 4}" fill="${col}" font-size="12" font-weight="700" stroke="rgba(0,0,0,0.6)" stroke-width="3" paint-order="stroke">${m.label}</text>`
          }
        }

        // where braking has to start
        if (view.brake) {
          const [x, y] = px(view.brake.x, view.brake.y).split(',')
          const col = view.brake.state == 'late' ? '#e74c3c' : (view.brake.state == 'brake' ? '#e67e22' : '#ffd166')
          h += `<line x1="${+x - 10}" x2="${+x + 10}" y1="${y}" y2="${y}" stroke="${col}" stroke-width="3" stroke-linecap="round"/>`
          h += `<text x="${+x - 26}" y="${+y + 4}" fill="${col}" font-size="11" font-weight="700">B</text>`
        }

        // the car, pointing up
        h += `<polygon points="${cx},${cy - 9} ${cx - 6},${cy + 7} ${cx + 6},${cy + 7}" fill="#ffffff" stroke="#111" stroke-width="1"/>`

        svg.setAttribute('viewBox', `0 0 ${W} ${H}`)
        svg.innerHTML = h
      }

      scope.$on('CoDriverCoachUpdate', function (event, data) { draw(data) })
      bngApi.engineLua('if coDriverCoach then coDriverCoach.requestState() end')
    }
  }
}])
