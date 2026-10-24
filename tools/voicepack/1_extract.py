"""Extract mono audio from your recordings and list spoken segments (pauses >= 100 ms split).
Usage: python 1_extract.py rec1=path\to\take1.mkv [rec2=path\to\take2.mkv ...]"""
import os, json, sys, tempfile
import av, numpy as np, soundfile as sf
B = os.environ.get("CDC_VOICE_WORK") or os.path.join(tempfile.gettempdir(), "cdc_tests")  # work folder (see README.md)
os.makedirs(B, exist_ok=True)
files = dict(a.split("=", 1) for a in sys.argv[1:] if "=" in a)
if not files:
    sys.exit(__doc__)
for key, src in files.items():
    c = av.open(src); st = c.streams.audio[0]
    x = np.concatenate([f.to_ndarray().astype(np.float32) for f in c.decode(st)], axis=1).mean(axis=0)
    sr = st.codec_context.sample_rate
    sf.write(os.path.join(B, f"{key}.wav"), x, sr)
    hop = sr // 100
    db = 20 * np.log10(np.array([np.sqrt(np.mean(x[i:i+hop]**2)) for i in range(0, len(x)-hop, hop)]) + 1e-9)
    line = ''.join(' ' if v < -62 else ('.' if v < -50 else ('o' if v < -35 else '#')) for v in [db[i:i+10].max() for i in range(0, len(db), 10)])
    print(f"{key}: {os.path.basename(src)}  {len(x)/sr:.1f}s")
    for k in range(0, len(line), 100): print(f'  {k/10:5.1f}s |{line[k:k+100]}|')
