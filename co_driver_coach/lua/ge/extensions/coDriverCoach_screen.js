// Co-Driver Coach: drawing layer injected into a car's navigation screen (an HTML texture).
// It sits on top of the stock navigator page; window.coDriverView(data) draws the road
// ahead, or hides the layer (data = null) so the stock navigator shows through again.
(function () {
  if (window.__coDriverScreen) return
  window.__coDriverScreen = true

  var canvas = document.createElement('canvas')
  canvas.style.cssText = 'position:fixed;left:0;top:0;width:100%;height:100%;z-index:2147483647;display:none;'
  document.body.appendChild(canvas)
  var ctx = canvas.getContext('2d')

  function gradeColor (g) {
    if (g === undefined || g === null) return '#9aa3ad'
    if (g <= 1) return '#ff6b5e'
    if (g === 2) return '#ff9f43'
    if (g <= 4) return '#ffd166'
    if (g <= 6) return '#8fd694'
    return '#7cc4ff'
  }

  window.coDriverView = function (d) {
    if (!d || !d.v || !d.v.pts || d.v.pts.length < 4) {
      canvas.style.display = 'none'
      return
    }
    canvas.style.display = 'block'
    var W = canvas.width = window.innerWidth
    var H = canvas.height = window.innerHeight
    var P = d.v.pts
    var u = Math.max(1, H / 128) // scale for line widths and text, screens are 128-512 px tall

    ctx.fillStyle = '#0d1014'
    ctx.fillRect(0, 0, W, H)

    // car near the bottom middle; zoom out with speed, and sideways on twisty roads (max 3x)
    var cx = W / 2, cy = H - 10 * u
    var range = Math.min(Math.max(d.v.speed * 5 + 60, 80), 260)
    var maxX = 1
    for (var i = 0; i < P.length; i += 2) if (P[i + 1] <= range) maxX = Math.max(maxX, Math.abs(P[i]))
    var sV = (H - 18 * u) / range
    var s = Math.max(Math.min(sV, (W / 2 - 8 * u) / maxX), sV / 3)
    function X (i) { return cx + P[2 * i - 2] * s }
    function Y (i) { return cy - P[2 * i - 1] * s }
    function line (i0, i1, color, width) {
      ctx.beginPath()
      ctx.moveTo(X(i0), Y(i0))
      for (var k = i0 + 1; k <= i1; k++) ctx.lineTo(X(k), Y(k))
      ctx.strokeStyle = color
      ctx.lineWidth = width
      ctx.lineCap = 'round'
      ctx.lineJoin = 'round'
      ctx.stroke()
    }

    var n = P.length / 2
    line(1, n, '#59616b', 5 * u)
    var marks = d.v.marks || []
    for (var m = 0; m < marks.length; m++) {
      var mk = marks[m]
      if (mk.kind !== 'crest' && mk.i1 > mk.i0) line(mk.i0, mk.i1, gradeColor(mk.grade), 4 * u)
    }
    ctx.font = 'bold ' + Math.round(10 * u) + 'px sans-serif'
    ctx.textBaseline = 'middle'
    for (m = 0; m < marks.length; m++) {
      mk = marks[m]
      if (!mk.label) continue
      var lx = cx + mk.x * s + 6 * u, ly = cy - mk.y * s
      ctx.lineWidth = 3 * u
      ctx.strokeStyle = 'rgba(0,0,0,0.7)'
      ctx.strokeText(mk.label, lx, ly)
      ctx.fillStyle = gradeColor(mk.grade)
      ctx.fillText(mk.label, lx, ly)
    }
    if (d.v.brake) {
      var bx = cx + d.v.brake.x * s, by = cy - d.v.brake.y * s
      ctx.strokeStyle = d.v.brake.state === 'late' ? '#e74c3c' : (d.v.brake.state === 'brake' ? '#e67e22' : '#ffd166')
      ctx.lineWidth = 3 * u
      ctx.beginPath(); ctx.moveTo(bx - 9 * u, by); ctx.lineTo(bx + 9 * u, by); ctx.stroke()
    }
    // the car
    ctx.fillStyle = '#ffffff'
    ctx.beginPath()
    ctx.moveTo(cx, cy - 8 * u); ctx.lineTo(cx - 5 * u, cy + 5 * u); ctx.lineTo(cx + 5 * u, cy + 5 * u)
    ctx.closePath(); ctx.fill()

    // next call, top left
    if (d.n) {
      ctx.textBaseline = 'top'
      ctx.font = 'bold ' + Math.round(17 * u) + 'px sans-serif'
      ctx.fillStyle = gradeColor(d.n.grade)
      ctx.fillText(d.n.text, 6 * u, 5 * u)
      ctx.font = Math.round(11 * u) + 'px sans-serif'
      ctx.fillStyle = '#c8ced6'
      ctx.fillText(d.n.dist + ' m' + (d.n.speed ? '   max ' + d.n.speed + ' ' + d.u : ''), 6 * u, 25 * u)
    }
    if (d.b && d.b !== 'none' && d.b !== 'soon') {
      ctx.textBaseline = 'top'
      ctx.font = 'bold ' + Math.round(13 * u) + 'px sans-serif'
      ctx.fillStyle = d.b === 'late' ? '#e74c3c' : '#e67e22'
      var t = d.b === 'late' ? 'TOO FAST' : 'BRAKE'
      ctx.fillText(t, W - ctx.measureText(t).width - 6 * u, 5 * u)
    }
  }
})()
