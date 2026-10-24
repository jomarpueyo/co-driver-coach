"""Voice review: check what the race engineer heard and how it answered.

Run tools/voice_review.bat (or `python tools/voice_review.py`), which opens http://127.0.0.1:8766 in your
browser. Every push-to-talk the bridge logged is listed newest first: play the clip, see what Whisper heard
(and how sure it was), type the right words or mark it right, and rate the answer. From your corrections it
learns phrase fixes for mishearings that come back (two or more times) and extra words for Whisper's
vocabulary; the bridge picks them up from voicelog/fixes.json on the next question, no restart needed.

Files (in the game's settings/coDriverCoach/engineer/voicelog/): log.jsonl (written by engineer.py),
*.wav (the clips), corrections.jsonl and fixes.json (written here). Only this computer can open the page.
"""
import difflib
import http.server
import json
import math
import os
import re
import secrets
import sys
import threading
import webbrowser

USER = os.path.join(os.environ.get("LOCALAPPDATA", ""), "BeamNG", "BeamNG.drive", "current")
LOG_DIR = os.environ.get("VOICE_LOG_DIR") or os.path.join(USER, "settings", "coDriverCoach", "engineer", "voicelog")
LOG = os.path.join(LOG_DIR, "log.jsonl")
CORR = os.path.join(LOG_DIR, "corrections.jsonl")
FIXES = os.path.join(LOG_DIR, "fixes.json")
PORT = int(os.environ.get("VOICE_REVIEW_PORT", "8766"))
# Only the page this server serves may use it: requests must name this server as their Host (so a
# web page can't reach it through DNS rebinding), writes must carry this run's token (a custom header,
# which other sites can't send without a CORS preflight this server never grants) and, when the
# browser says where they come from, an Origin on this server.
TOKEN = secrets.token_hex(16)
CLIP_NAME = re.compile(r"^\d{8}_\d{6}_\d{3}\.wav$")
STOP = set(("a an the i my me is it to of and in on at for was what's whats how what did do does that this you your be "
            "into with from out off up down are am can could would should there here then than").split())
lock = threading.Lock()


def read_jsonl(path):
    out = []
    for p in (path + ".old", path):
        if os.path.exists(p):
            with open(p, encoding="utf-8") as f:
                for line in f:
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        pass
    return out


def words(s):
    return re.findall(r"[a-z0-9']+", (s or "").lower())


def wer(heard, correct):
    """Word error rate: edits needed to turn what was heard into the right words, per right word."""
    a, b = words(heard), words(correct)
    if not b:
        return 0.0 if not a else 1.0
    d = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(b) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] != b[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(b)] / len(b)


def corrections():
    """The latest correction and rating per clip (or per typed question)."""
    out = {}
    for c in read_jsonl(CORR):
        e = out.setdefault(c.get("id"), {})
        e.update({k: v for k, v in c.items() if v is not None})
    return out


def entries():
    recs = read_jsonl(LOG)
    corr = corrections()
    heard, answers = {}, []
    for r in recs:
        if r.get("type") == "heard":
            heard[r["id"]] = dict(r)
        elif r.get("type") == "answer":
            answers.append(r)
    out = list(heard.values())
    for a in answers:
        h = heard.get(a.get("heard")) if a.get("heard") else None
        if h is not None:
            h["answer"] = a
        else:  # typed in the panel, or the clip was not linked
            out.append({"type": "typed", "id": "q%d_%s" % (a.get("t", 0), abs(hash(a.get("q", ""))) % 100000), "t": a.get("t", 0),
                        "mode": a.get("mode"), "text": a.get("q"), "answer": a})
    for e in out:
        c = corr.get(e["id"])
        if c:
            e["review"] = c
            if c.get("correct") is not None and e.get("type") == "heard":
                e["wer"] = round(wer(e.get("text"), c["correct"]), 3)
        e["clipOk"] = bool(e.get("wav")) and os.path.exists(os.path.join(LOG_DIR, e["wav"]))
    out.sort(key=lambda e: e.get("t", 0), reverse=True)
    return out


def stats(es):
    heard = [e for e in es if e.get("type") == "heard"]
    reviewed = [e for e in heard if "wer" in e]
    n_words = sum(len(words(e["review"]["correct"])) for e in reviewed) or 1
    errs = sum(e["wer"] * len(words(e["review"]["correct"])) for e in reviewed)
    ratings = {}
    for e in es:
        r = (e.get("review") or {}).get("rating")
        if r:
            ratings[r] = ratings.get(r, 0) + 1
    avg = lambda xs: round(sum(xs) / len(xs), 2) if xs else None
    return {"heard": len(heard), "typed": len(es) - len(heard), "reviewed": len(reviewed),
            "exact": sum(1 for e in reviewed if e["wer"] == 0), "wer": round(errs / n_words, 3) if reviewed else None,
            "rejected": sum(1 for e in heard if e.get("rejected")), "retried": sum(1 for e in heard if e.get("retried")),
            "sttSecs": avg([e["sttSecs"] for e in heard if e.get("sttSecs") is not None]),
            "answerSecs": avg([e["answer"]["secs"] for e in es if e.get("answer") and e["answer"].get("secs") is not None]),
            "ratings": ratings}


def rebuild_fixes():
    """Phrase fixes (the same mishearing corrected at least twice) and vocabulary (words Whisper missed)."""
    es = [e for e in entries() if e.get("type") == "heard" and (e.get("review") or {}).get("correct") is not None]
    pairs, vocab = {}, {}
    for e in es:
        a, b = words(e.get("text")), words(e["review"]["correct"])
        for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b).get_opcodes():
            if op == "replace" and 1 <= i2 - i1 <= 4 and 1 <= j2 - j1 <= 4:
                k1, l1 = i1, j1
                if i2 - i1 == 1 and i1 > 0 and j1 > 0:  # one word: keep the word before it, so "slip angle" stays
                    k1, l1 = i1 - 1, j1 - 1
                key = (" ".join(a[k1:i2]), " ".join(b[l1:j2]))
                pairs[key] = pairs.get(key, 0) + 1
            if op in ("replace", "insert"):
                for w in b[j1:j2]:
                    if w not in STOP and not w.isdigit() and len(w) > 2:
                        vocab[w] = vocab.get(w, 0) + 1
    old = {}
    if os.path.exists(FIXES):
        try:
            old = {p["heard"]: p.get("on", True) for p in json.load(open(FIXES, encoding="utf-8")).get("pairs", [])}
        except (ValueError, OSError, KeyError, TypeError):
            pass
    out = {"pairs": [{"heard": h, "correct": c, "count": n, "on": old.get(h, True)}
                     for (h, c), n in sorted(pairs.items(), key=lambda x: -x[1]) if n >= 2 and len(h) > 1],
           "vocab": [w for w, _ in sorted(vocab.items(), key=lambda x: -x[1])][:20]}
    os.makedirs(LOG_DIR, exist_ok=True)
    tmp = FIXES + ".tmp"
    json.dump(out, open(tmp, "w", encoding="utf-8"), indent=1)
    os.replace(tmp, FIXES)
    return out


def fixes():
    try:
        return json.load(open(FIXES, encoding="utf-8"))
    except (OSError, ValueError):
        return {"pairs": [], "vocab": []}


PAGE = r"""<!doctype html><html><head><meta charset="utf-8"><title>Engineer voice review</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root { --bg:#111418; --card:#1a1e24; --line:#2a3039; --text:#e6e9ed; --dim:#8b95a1; --ok:#6fd38a; --warn:#ffcf66; --bad:#ff7b6b; --acc:#4b8ef0; }
body { margin:0; background:var(--bg); color:var(--text); font:14px/1.45 system-ui, Segoe UI, Roboto, sans-serif; }
header { padding:16px 20px; border-bottom:1px solid var(--line); position:sticky; top:0; background:var(--bg); z-index:2; }
h1 { font-size:17px; margin:0 0 8px; }
.stats { display:flex; flex-wrap:wrap; gap:8px 18px; color:var(--dim); }
.stats b { color:var(--text); }
.bar { display:flex; gap:8px; margin-top:10px; flex-wrap:wrap; align-items:center; }
button, .chip { background:#262c35; color:var(--text); border:1px solid var(--line); border-radius:6px; padding:4px 10px; cursor:pointer; font:inherit; }
button:hover { border-color:var(--acc); }
button.on { background:var(--acc); border-color:var(--acc); }
main { padding:12px 20px 40px; max-width:1200px; }
.e { background:var(--card); border:1px solid var(--line); border-radius:8px; padding:10px 12px; margin:10px 0; }
.top { display:flex; gap:10px; align-items:center; flex-wrap:wrap; color:var(--dim); font-size:12.5px; }
.badge { padding:1px 7px; border-radius:10px; font-size:12px; }
.hi { background:rgba(111,211,138,.15); color:var(--ok); } .mid { background:rgba(255,207,102,.15); color:var(--warn); } .lo { background:rgba(255,123,107,.15); color:var(--bad); }
.heard { display:flex; gap:8px; margin:8px 0 4px; align-items:center; }
.heard input { flex:1; background:#0f1215; color:var(--text); border:1px solid var(--line); border-radius:6px; padding:6px 8px; font:inherit; }
.raw { color:var(--dim); font-size:12.5px; }
.ans { margin-top:6px; padding:6px 9px; border-left:3px solid var(--acc); background:rgba(75,142,240,.08); border-radius:4px; }
.rate { display:flex; gap:6px; margin-top:6px; flex-wrap:wrap; }
audio { height:30px; }
.fixes { margin-top:10px; color:var(--dim); font-size:13px; }
.fixes span { display:inline-block; margin:2px 8px 2px 0; }
.done { color:var(--ok); font-size:12.5px; }
@media (max-width:640px) { header, main { padding-left:16px; padding-right:16px; } .heard { flex-wrap:wrap; } }
</style></head><body>
<header><h1>Engineer voice review</h1><div class="stats" id="stats"></div>
<div class="bar"><span>Show</span>
<button data-f="all" class="on">all</button><button data-f="todo">not reviewed</button><button data-f="low">low confidence</button>
<button data-f="rejected">not heard</button><button data-f="typed">typed</button></div>
<div class="fixes" id="fixes"></div></header>
<main id="list"></main>
<script>
let data = null, filter = 'all'
const $ = s => document.querySelector(s)
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))
function conf(e) { if (e.logprob == null) return ''; const p = Math.round(Math.exp(e.logprob) * 100)
  return `<span class="badge ${p >= 75 ? 'hi' : p >= 50 ? 'mid' : 'lo'}" title="average word probability from Whisper">${p}% sure</span>` }
function when(t) { return new Date(t * 1000).toLocaleString() }
async function load() { data = await (await fetch('/api/data')).json(); render() }
async function post(url, body) { const r = await fetch(url, {method:'POST', headers:{'content-type':'application/json', 'x-review-token':'__TOKEN__'}, body:JSON.stringify(body)}); data = await r.json(); render() }
function render() {
  const s = data.stats
  $('#stats').innerHTML = `<span><b>${s.heard}</b> spoken, <b>${s.typed}</b> typed</span>
    <span><b>${s.reviewed}</b> reviewed${s.reviewed ? `, <b>${s.exact}</b> exactly right` : ''}</span>
    <span>word error rate <b>${s.wer == null ? '–' : (s.wer * 100).toFixed(1) + '%'}</b></span>
    <span><b>${s.rejected}</b> not heard, <b>${s.retried}</b> second tries</span>
    <span>hearing <b>${s.sttSecs == null ? '–' : s.sttSecs + ' s'}</b>, answers <b>${s.answerSecs == null ? '–' : s.answerSecs + ' s'}</b></span>
    <span>answers: ${Object.entries(s.ratings).map(([k, v]) => `${k} <b>${v}</b>`).join(', ') || 'none rated'}</span>`
  const f = data.fixes
  $('#fixes').innerHTML = (f.pairs.length ? 'Learned fixes (click to switch): ' + f.pairs.map(p =>
      `<span><button class="${p.on ? 'on' : ''}" data-fix="${esc(p.heard)}" data-on="${p.on ? 0 : 1}">"${esc(p.heard)}" → "${esc(p.correct)}" ×${p.count}</button></span>`).join('') : 'No learned fixes yet: they appear once the same mishearing is corrected twice.')
    + (f.vocab.length ? `<br>Extra vocabulary for Whisper: ${f.vocab.map(esc).join(', ')}` : '')
  let es = data.entries
  if (filter === 'todo') es = es.filter(e => !e.review)
  if (filter === 'low') es = es.filter(e => e.logprob != null && Math.exp(e.logprob) < 0.6)
  if (filter === 'rejected') es = es.filter(e => e.rejected)
  if (filter === 'typed') es = es.filter(e => e.type === 'typed')
  $('#list').innerHTML = es.map(e => {
    const r = e.review || {}, a = e.answer
    const heardText = r.correct != null ? r.correct : (e.text || '')
    return `<div class="e" data-id="${esc(e.id)}">
      <div class="top"><span>${when(e.t)}</span><span>${esc(e.mode || '')}</span>${e.type === 'typed' ? '<span>typed</span>' : conf(e)}
        ${e.retried ? '<span class="badge mid" title="low confidence: a wider second search">second try</span>' : ''}
        ${e.rejected ? `<span class="badge lo">not heard (${esc(e.rejected)})</span>` : ''}
        ${e.sttSecs != null ? `<span>${e.sttSecs} s to hear</span>` : ''}${e.audioSecs ? `<span>${e.audioSecs} s clip</span>` : ''}
        ${e.wer != null ? (e.wer === 0 ? '<span class="done">✓ heard right</span>' : `<span class="badge lo">${Math.round(e.wer * 100)}% words wrong</span>`) : ''}
        ${e.clipOk ? `<audio controls preload="none" src="/clip/${esc(e.wav)}"></audio>` : ''}</div>
      ${e.type === 'heard' ? `<div class="heard"><input value="${esc(heardText)}" placeholder="what you said">
        <button data-act="right" title="Whisper heard it right">✓ right</button><button data-act="save" title="save what you actually said">save correction</button></div>
        ${e.raw && e.raw !== e.text ? `<div class="raw">Whisper: ${esc(e.raw)}${e.firstTry ? ' · first try: ' + esc(e.firstTry) : ''}</div>` : (e.firstTry ? `<div class="raw">first try: ${esc(e.firstTry)}</div>` : '')}`
        : `<div class="heard">${esc(e.text)}</div>`}
      ${a ? `<div class="ans">${esc(a.a)}<span class="raw"> · ${esc(a.source)}${a.secs != null ? ', ' + a.secs + ' s' : ''}${a.actions ? ', changed the car' : ''}</span></div>
        <div class="rate">${['clear', 'too long', 'unclear', 'wrong'].map(k => `<button data-rate="${k}" class="${r.rating === k ? 'on' : ''}">${k}</button>`).join('')}</div>` : ''}
    </div>` }).join('') || '<p>Nothing here yet. Talk to the engineer in the game (push to talk), then reload this page.</p>'
}
document.addEventListener('click', ev => {
  const b = ev.target.closest('button'); if (!b) return
  if (b.dataset.f) { filter = b.dataset.f; document.querySelectorAll('[data-f]').forEach(x => x.classList.toggle('on', x === b)); render(); return }
  if (b.dataset.fix) { post('/api/fix', {heard: b.dataset.fix, on: b.dataset.on === '1'}); return }
  const card = b.closest('.e'); if (!card) return
  const id = card.dataset.id, e = data.entries.find(x => x.id === id)
  if (b.dataset.act === 'right') post('/api/correct', {id, correct: e.text || ''})
  if (b.dataset.act === 'save') post('/api/correct', {id, correct: card.querySelector('input').value.trim()})
  if (b.dataset.rate) post('/api/correct', {id, rating: b.dataset.rate})
})
document.addEventListener('keydown', ev => { if (ev.key === 'Enter' && ev.target.matches('.heard input')) ev.target.closest('.e').querySelector('[data-act=save]').click() })
load()
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def local_host(self):
        host = (self.headers.get("Host") or "").lower()
        port = str(self.server.server_address[1])
        return host in ("127.0.0.1:" + port, "localhost:" + port)

    def own_origin(self):
        origin = self.headers.get("Origin")
        port = str(self.server.server_address[1])
        return origin is None or origin.lower() in ("http://127.0.0.1:" + port, "http://localhost:" + port)

    def state(self):
        es = entries()
        return json.dumps({"entries": es, "stats": stats(es), "fixes": fixes()})

    def do_GET(self):
        if not self.local_host():
            return self.send(403, "forbidden", "text/plain")
        if self.path in ("/", "/index.html"):
            return self.send(200, PAGE.replace("__TOKEN__", TOKEN), "text/html; charset=utf-8")
        if self.path == "/api/data":
            with lock:
                return self.send(200, self.state())
        if self.path.startswith("/clip/"):
            name = self.path[6:]
            path = os.path.join(LOG_DIR, name)
            if CLIP_NAME.match(name) and os.path.exists(path):
                return self.send(200, open(path, "rb").read(), "audio/wav")
        self.send(404, "not found", "text/plain")

    def do_POST(self):
        if not (self.local_host() and self.own_origin() and secrets.compare_digest(self.headers.get("X-Review-Token", ""), TOKEN)):
            return self.send(403, "forbidden", "text/plain")
        try:
            n = int(self.headers.get("Content-Length", 0))
            if n < 0 or n > 100_000:
                return self.send(413, "too large", "text/plain")
            body = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self.send(400, "bad json", "text/plain")
        if not isinstance(body, dict):
            return self.send(400, "bad json", "text/plain")
        with lock:
            os.makedirs(LOG_DIR, exist_ok=True)
            if self.path == "/api/correct" and body.get("id"):
                rec = {"id": str(body["id"])}
                if isinstance(body.get("correct"), str):
                    rec["correct"] = body["correct"][:500]
                if body.get("rating") in ("clear", "too long", "unclear", "wrong"):
                    rec["rating"] = body["rating"]
                with open(CORR, "a", encoding="utf-8") as f:
                    f.write(json.dumps(rec) + "\n")
                if "correct" in rec:
                    rebuild_fixes()
                return self.send(200, self.state())
            if self.path == "/api/fix" and body.get("heard"):
                f = fixes()
                for p in f.get("pairs", []):
                    if p.get("heard") == body["heard"]:
                        p["on"] = bool(body.get("on"))
                json.dump(f, open(FIXES, "w", encoding="utf-8"), indent=1)
                return self.send(200, self.state())
        self.send(404, "not found", "text/plain")


def main():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    url = "http://127.0.0.1:%d/" % PORT
    print("Engineer voice review at", url, "(close this window to stop)")
    print("Log folder:", LOG_DIR)
    if "--no-browser" not in sys.argv:
        webbrowser.open(url)
    srv.serve_forever()


if __name__ == "__main__":
    main()
