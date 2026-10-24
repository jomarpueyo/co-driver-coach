"""Build the 97-clip voicepack: lines 1-90 from rec1, 91-97 from the rec2 retake.
Each clip: trimmed to the voice, levelled to the game clips, soft fades and a little padding."""
import json, os
import numpy as np
import soundfile as sf

import tempfile
B = os.environ.get("CDC_VOICE_WORK") or os.path.join(tempfile.gettempdir(), "cdc_tests")  # work folder (see README.md)
# clip names the coach looks up (no trailing _digits: the loader treats those as alternate takes)
KEYS = ["one_left", "one_right", "two_left", "two_right", "three_left", "three_right", "four_left", "four_right",
        "five_left", "five_right", "six_left", "six_right",
        "flat_left", "flat_right", "easy_left", "easy_right", "medium_left", "medium_right", "hard_left", "hard_right",
        "square_left", "square_right", "hairpin_left", "hairpin_right", "tight_hairpin_left", "tight_hairpin_right",
        "tightens", "opens", "long", "very_long", "dont_cut", "keep_in", "keep_left", "keep_right", "narrows", "into", "and",
        "crest", "big_crest", "small_crest", "over_crest", "jump", "dip", "bumpy", "slippy", "caution", "double_caution",
        "50", "100", "150", "200", "250", "300", "400", "500",
        "brake", "brake_now", "brake_hard", "slow_down", "easy", "flat_out",
        "oversteer", "understeer", "countersteer", "ease_off", "catch_it", "nice_save",
        "shift_up", "shift_down",
        "stage_ready", "countdown_three", "countdown_two", "countdown_one", "go", "halfway", "one_km_to_go", "five_hundred_to_go", "over_finish",
        "drive_complete", "nice_drive", "great_drive", "that_was_messy", "overall_grade", "grade_a", "grade_b", "grade_c", "grade_d", "grade_f",
        "plus", "minus",
        "focus_braking", "focus_entry", "focus_pace", "focus_control", "focus_smooth", "focus_road", "focus_gears",
        "good_corner", "too_hot", "too_slow", "clean_so_far", "off_the_road", "back_on_road", "ouch", "are_you_okay", "reset",
        "lets_go", "loading", "scenario_ready", "restarting", "stage_cancelled", "surface_tarmac", "surface_gravel", "surface_snow",
        "coach_on", "coach_off", "new_best", "better_than_last", "same_as_last", "worse_than_last"]
assert len(KEYS) == 120

align = json.load(open(os.path.join(B, "alignment.json")))
sources = [(align[str(n)]["rec"], {"offset": align[str(n)]["start"], "end": align[str(n)]["end"]}) for n in range(1, 121)]

audio = {k: sf.read(os.path.join(B, f"{k}.wav")) for k in ("rec3", "rec4")}
TARGET_RMS = 10 ** (-20.4 / 20)  # the game's own co-driver clips


def voiced_span(x, sr, a, b):
    hop = sr // 200
    seg = x[int(a * sr):int(b * sr)]
    db = 20 * np.log10(np.array([np.sqrt(np.mean(seg[i:i + hop] ** 2)) for i in range(0, max(len(seg) - hop, 1), hop)]) + 1e-9)
    on = np.where(db > -55)[0]
    if len(on) == 0:
        return a, b
    return max(a, a + on[0] / 200 - 0.03), min(b, a + (on[-1] + 1) / 200 + 0.05)


out_dir = os.path.join(B, "voice_custom3", "audio")
os.makedirs(out_dir, exist_ok=True)
for f in os.listdir(out_dir):
    os.remove(os.path.join(out_dir, f))
check_dir = os.path.join(B, "voice_check3")
os.makedirs(check_dir, exist_ok=True)
for f in os.listdir(check_dir):
    os.remove(os.path.join(check_dir, f))

meta = {}
for n, (key, (rec, c)) in enumerate(zip(KEYS, sources), 1):
    x, sr = audio[rec]
    a, b = voiced_span(x, sr, c["offset"], c["end"])
    clip = x[int(a * sr):int(b * sr)].copy()
    loud = clip[np.abs(clip) > 0.02 * np.max(np.abs(clip))]
    gain = min(10 ** (2 / 20), TARGET_RMS / (np.sqrt(np.mean(loud ** 2)) + 1e-9))  # at most +2 dB
    clip *= gain
    peak = np.max(np.abs(clip))
    if peak > 0.89:
        clip *= 0.89 / peak
    fi, fo = int(0.015 * sr), int(0.03 * sr)
    clip[:fi] *= np.sin(np.linspace(0, np.pi / 2, fi)) ** 2
    clip[-fo:] *= np.cos(np.linspace(0, np.pi / 2, fo)) ** 2
    clip = np.concatenate([np.zeros(int(0.03 * sr)), clip, np.zeros(int(0.04 * sr))])
    name = f"pacenote_{key}.ogg"
    sf.write(os.path.join(out_dir, name), clip, sr, format="OGG", subtype="VORBIS")
    meta[name] = {"audioLen": round(len(clip) / sr, 6)}
    # recognizer check copy: 16 kHz with 300 ms of silence either side
    chk = np.convolve(clip, np.ones(3) / 3, "same")[::3]
    pad = np.zeros(int(0.3 * sr / 3))
    sf.write(os.path.join(check_dir, f"{n:02d}.wav"), np.concatenate([pad, chk / (np.max(np.abs(chk)) + 1e-9) * 0.9, pad]), sr // 3, subtype="PCM_16")

json.dump(meta, open(os.path.join(B, "voice_custom3", "metadata.json"), "w"), indent=2)
lens = [v["audioLen"] for v in meta.values()]
print(f"wrote {len(meta)} clips, {min(lens):.2f}-{max(lens):.2f}s long")
