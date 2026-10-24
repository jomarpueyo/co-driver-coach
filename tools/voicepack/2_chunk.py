"""Cut each recording into short chunks (<= ~4 s) at pauses, for one-utterance-per-chunk recognition."""
import json, os
import numpy as np, soundfile as sf

import tempfile
B = os.environ.get("CDC_VOICE_WORK") or os.path.join(tempfile.gettempdir(), "cdc_tests")  # work folder (see README.md)
out = os.path.join(B, "chunks")
os.makedirs(out, exist_ok=True)
for f in os.listdir(out):
    os.remove(os.path.join(out, f))

import sys
KEYS = sys.argv[1:] or ["rec1", "rec2"]
index = []
for key in KEYS:
    x, sr = sf.read(os.path.join(B, f"{key}.wav"))
    hop = sr // 100
    db = 20 * np.log10(np.array([np.sqrt(np.mean(x[i:i + hop] ** 2)) for i in range(0, len(x) - hop, hop)]) + 1e-9)
    voiced = db > -52
    # speech segments split at pauses >= 100 ms
    segs, start, quiet = [], None, 0
    for i, v in enumerate(voiced):
        if v:
            if start is None:
                start = i
            quiet = 0
        elif start is not None:
            quiet += 1
            if quiet >= 10:
                end = i - quiet
                if end - start > 8:
                    segs.append([start, end])
                start, quiet = None, 0
    if start is not None:
        segs.append([start, len(voiced) - 1])
    # group into chunks of at most ~4 s, cutting in the middle of the pause between segments
    chunks, cur = [], [segs[0]]
    for s in segs[1:]:
        if True:  # one chunk per speech segment
            chunks.append(cur)
            cur = [s]
        else:
            cur.append(s)
    chunks.append(cur)
    y = np.convolve(x, np.ones(3) / 3, "same")
    for k, ch in enumerate(chunks):
        prev_end = chunks[k - 1][-1][1] if k else 0
        next_start = chunks[k + 1][0][0] if k + 1 < len(chunks) else len(db)
        a = max(0, (ch[0][0] + prev_end) // 2) if k else max(0, ch[0][0] - 20)
        b = min(len(db), (ch[-1][1] + next_start) // 2)
        clip = y[a * hop:b * hop:3]
        clip = clip / (np.max(np.abs(clip)) + 1e-9) * 0.9
        name = f"{key}_c{k:03d}.wav"
        sf.write(os.path.join(out, name), clip, sr // 3, subtype="PCM_16")
        index.append({"rec": key, "file": name, "offset": a / 100, "end": b / 100})
    print(key, len(segs), "segments ->", len(chunks), "chunks")
json.dump(index, open(os.path.join(out, "index.json"), "w"), indent=1)
