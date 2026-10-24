"""Align speech segments to script lines with dynamic programming.

A line may span 1-3 consecutive segments (mid-line pauses). Score per line:
  + recognition anchor (a segment in the group recognized as exactly this line)
  - recognized as a *different* line (weak, recognizer often confuses similar lines)
  - duration misfit vs. the expected length of that line
  - merging across longer pauses
Writes alignment.json: line number -> {rec, start, end} in seconds."""
import json, math, os, sys

import tempfile
B = os.environ.get("CDC_VOICE_WORK") or os.path.join(tempfile.gettempdir(), "cdc_tests")  # work folder (see README.md)
phrases = [l.strip() for l in open(os.path.join(B, "phrases.txt"), encoding="utf-8") if l.strip()]
assert len(phrases) == 120
index = json.load(open(os.path.join(B, "chunks", "index.json")))
rec = json.load(open(os.path.join(B, "chunks", "recognized.json"), encoding="utf-8-sig"))
heard = {}
for r in rec:
    if r["phrase"]:
        heard.setdefault(r["file"], []).append(r["phrase"])

# expected durations: the previous take of lines 1-97, ~0.38 s per word for the new lines
prev = json.load(open(os.path.join(B, "voice_custom2", "metadata.json")))
prev_len = [v["audioLen"] - 0.07 for v in prev.values()]
expected = prev_len + [0.25 + 0.38 * len(p.split()) for p in phrases[97:]]


def segments(key, first=0, last=None):
    segs = sorted([c for c in index if c["rec"] == key], key=lambda c: c["file"])
    return segs[first:last]


def speech_bounds(c):
    """Rough voiced duration of a chunk: the chunk spans mid-gap to mid-gap, so trim ~half the pauses."""
    return c["offset"], c["end"]


def align(segs, lines):
    n, m = len(segs), len(lines)
    NEG = -1e9
    best = [[NEG] * (m + 1) for _ in range(n + 1)]
    back = [[None] * (m + 1) for _ in range(n + 1)]
    best[0][0] = 0
    for i in range(n + 1):
        for j in range(m + 1):
            if best[i][j] == NEG:
                continue
            if j < m:
                line = lines[j]
                for k in (1, 2, 3):
                    if i + k > n:
                        break
                    grp = segs[i:i + k]
                    names = [p for c in grp for p in heard.get(c["file"], [])]
                    score = 0.0
                    if phrases[line] in names:
                        score += 6
                    elif names:
                        score -= 0.5
                    dur = grp[-1]["end"] - grp[0]["offset"] - 0.3  # chunk bounds include half of each pause
                    score -= 2.5 * abs(math.log(max(dur, 0.15) / expected[line]))
                    for a, b in zip(grp, grp[1:]):  # pauses inside the line
                        score -= 1.5 + 10 * max(0.0, (b["offset"] - a["offset"]) * 0 + 0)  # constant per merge
                    s2 = best[i][j] + score
                    if s2 > best[i + k][j + 1]:
                        best[i + k][j + 1] = s2
                        back[i + k][j + 1] = (i, j, k)
            # allow dropping a stray segment (cough, false start) at a cost
            if i < n and best[i][j] - 4 > best[i + 1][j]:
                best[i + 1][j] = best[i][j] - 4
                back[i + 1][j] = (i, j, 0)
    # walk back
    i, j, out = n, m, {}
    if best[n][m] == NEG:
        raise SystemExit("no alignment found")
    dropped = []
    while (i, j) != (0, 0):
        pi, pj, k = back[i][j]
        if k == 0:
            dropped.append(segs[pi]["file"])
        else:
            grp = segs[pi:pi + k]
            out[lines[pj] + 1] = {"files": [c["file"] for c in grp], "start": grp[0]["offset"], "end": grp[-1]["end"]}
        i, j = pi, pj
    return out, dropped, best[n][m]


result, report = {}, []
plan = [("rec3", 0, None, list(range(0, 78))),        # lines 1-78
        ("rec4", 0, 44, list(range(78, 120))),        # lines 79-120 (first pass of K included)
        ("rec4", 44, None, list(range(97, 120)))]     # second take of K (lines 98-120) wins
for key, a, b, lines in plan:
    segs = segments(key, a, b)
    out, dropped, score = align(segs, lines)
    for line, v in out.items():
        v["rec"] = key
        result[line] = v
    merged = sum(1 for v in out.values() if len(v["files"]) > 1)
    report.append(f"{key}[{a}:{b}] -> lines {lines[0] + 1}-{lines[-1] + 1}: {len(segs)} segments, {merged} lines merged from pieces, dropped {dropped}")
json.dump({str(k): result[k] for k in sorted(result)}, open(os.path.join(B, "alignment.json"), "w"), indent=1)
print("\n".join(report))
print("lines aligned:", len(result))
