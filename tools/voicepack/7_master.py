"""Make the custom voicepack louder: bring every clip to the same loudness target and
soft-limit the peaks (tanh curve) so nothing clips. Clip lengths are unchanged, so
metadata.json stays valid. Usage: python 7_master.py [target_dBFS]  (default -14)"""
import glob, os, sys
import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
AUDIO = os.path.join(HERE, "..", "co_driver_coach", "lua", "ge", "extensions", "gameplay", "rally",
                     "compositors", "voicepacks", "custom", "audio")
TARGET_DB = float(sys.argv[1]) if len(sys.argv) > 1 else -14.0
CEILING = 0.97


def voiced_rms(x):
    loud = x[np.abs(x) > 0.02 * np.max(np.abs(x))]
    return np.sqrt(np.mean(loud ** 2)) if len(loud) else 0.0


def soft_limit(x):
    """Linear below ~70% of the ceiling, smoothly rounded above it, never past the ceiling."""
    knee = 0.7 * CEILING
    y = x.copy()
    over = np.abs(x) > knee
    y[over] = np.sign(x[over]) * (knee + (CEILING - knee) * np.tanh((np.abs(x[over]) - knee) / (CEILING - knee)))
    return y


before, after = [], []
files = sorted(glob.glob(os.path.join(AUDIO, "*.ogg")))
for f in files:
    x, sr = sf.read(f)
    if x.ndim > 1:
        x = x.mean(axis=1)
    r = voiced_rms(x)
    if r <= 0:
        continue
    before.append(20 * np.log10(r))
    y = soft_limit(x * (10 ** (TARGET_DB / 20) / r))
    after.append(20 * np.log10(voiced_rms(y)))
    sf.write(f, y, sr, format="OGG", subtype="VORBIS")
print(f"{len(files)} clips: loudness {np.median(before):.1f} -> {np.median(after):.1f} dBFS (median), peaks capped at {20 * np.log10(CEILING):.1f} dBFS")
