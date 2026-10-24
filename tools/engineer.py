"""Co-Driver Coach race-engineer bridge.

Runs next to BeamNG and gives the coach a voice-driven race engineer:
  * push-to-talk speech-to-text: faster-whisper on the CPU (local), else Windows dictation
  * answers from Claude Haiku when ANTHROPIC_API_KEY is set, rule-based answers otherwise
  * light, temporary car adjustments mid-drive when the driver asks (brake bias, brake strength,
    force feedback, and the car's electronics: drive mode, ESC, traction control, ABS, launch
    control, AWD centre lock): Haiku tools, or simple phrases without Haiku; the game applies them
  * spoken replies: Kokoro (natural local voice), else Piper, else Windows text-to-speech

Whisper and Piper live in tools/.venv (set up by tools/engineer_setup.bat); voice and
model choices are in tools/engineer_config.json.

The game and this bridge talk through small JSON files in the BeamNG user folder
(settings/coDriverCoach/engineer/), so the mod never touches the network.
The API key can also go in tools/.anthropic_key (git-ignored).

Usage: python tools/engineer.py      (or double-click tools/engineer.bat)
"""
import glob
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
USER = os.path.join(os.environ.get("LOCALAPPDATA", ""), "BeamNG", "BeamNG.drive", "current")
DIR = os.path.join(USER, "settings", "coDriverCoach", "engineer")
GAME_BEAT = os.path.join(DIR, "game.json")  # the game touches it every 20 s while it runs
MODEL = "claude-haiku-5-5"
API_URL = "https://api.anthropic.com/v1/messages"


def load_key():
    key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    path = os.path.join(HERE, ".anthropic_key")
    if not key and os.path.exists(path):
        key = open(path, encoding="utf-8").read().strip()
    return key


API_KEY = load_key()

CONFIG = {"tts": "kokoro", "kokoro_voice": "af_heart", "speed": 0.95, "tts_threads": 4, "voice": "en_GB-jenny_dioco-medium",
          "style": "natural", "whisper": "base.en", "threads": 2, "volume": 1.0}
try:  # personal preferences (git-ignored); engineer_config.example.json shows the keys
    CONFIG.update(json.load(open(os.path.join(HERE, "engineer_config.json"), encoding="utf-8")))
except (OSError, ValueError):
    pass
MODELS = os.path.join(HERE, "models")

# Windows priority classes. The bridge runs below normal so speech-to-text and the voice yield
# the CPU to the game (measured: about 2.2 ms per frame while Whisper or Kokoro runs at normal).
PRIORITY = {"idle": 0x40, "below_normal": 0x4000, "normal": 0x20}


def set_priority(pid=None, level=None):
    """Set a process's priority class (this process when pid is None). Returns True on success."""
    level = level or CONFIG.get("priority", "below_normal")
    if os.name != "nt" or level not in PRIORITY:
        return False
    import ctypes
    from ctypes import wintypes
    k32 = ctypes.windll.kernel32
    # 64-bit handles: declare the types, or ctypes truncates them to 32-bit ints and the call fails
    k32.GetCurrentProcess.restype = wintypes.HANDLE
    k32.OpenProcess.restype = wintypes.HANDLE
    k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    k32.SetPriorityClass.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    k32.SetPriorityClass.restype = wintypes.BOOL
    k32.CloseHandle.argtypes = [wintypes.HANDLE]
    if pid is None:
        handle, close = k32.GetCurrentProcess(), False
    else:
        handle, close = k32.OpenProcess(0x0200 | 0x0400, False, int(pid)), True  # SET_INFORMATION | QUERY
        if not handle:
            return False
    ok = bool(k32.SetPriorityClass(handle, PRIORITY[level]))
    if close:
        k32.CloseHandle(handle)
    return ok

# questions drivers ask, boosted in the recogniser so they come out right
NUMBERS = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
           "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
           "eighteen", "nineteen", "twenty"]
PHRASES = [
    "how are my brakes", "how are the brakes", "brake temperatures", "are my brakes fading",
    "how are my tires", "how are the tires", "tire temperatures", "tire pressures", "do I have a puncture",
    "how is the engine", "engine temperature", "is the engine overheating", "how much fuel", "how much fuel do I have",
    "any damage", "how bad is the damage", "how is the car", "status report", "car status", "give me a status report",
    "what is the weather", "how is the weather", "is it raining", "what time is it",
    "where am I losing time", "what should I work on", "what should I focus on", "how do I brake better",
    "how was that drive", "give me a debrief", "what was my worst corner", "how do I get faster",
    "am I braking too early", "am I braking too late", "how is my throttle", "am I coasting",
    "more front bias", "more rear bias", "move the bias forward", "move the bias back", "what is my brake bias",
    "more brake power", "less brake power", "brakes are too strong", "brakes are too weak",
    "force feedback lighter", "force feedback heavier", "FFB lighter", "FFB heavier", "make the wheel lighter",
    "undo that", "put it back", "back to stock", "sport mode", "comfort mode", "traction control off", "traction control on",
    "ESC off", "ESC on", "ABS off", "ABS on", "launch control on", "launch control off", "more center lock", "less center lock",
]
PHRASES += ["why was corner %s slow" % n for n in NUMBERS]
PHRASES += ["what happened in corner %s" % n for n in NUMBERS]
PHRASES += ["how do I fix corner %s" % n for n in NUMBERS]


# ---------------------------------------------------------------- speech helper

class WindowsSpeech:
    """The PowerShell speech helper, kept running; one command line in, one line out."""

    def __init__(self):
        self.lock = threading.Lock()
        self.ok, self.mic = False, False
        phrase_file = os.path.join(DIR, "phrases.txt")
        with open(phrase_file, "w", encoding="utf-8") as f:
            f.write("\n".join(PHRASES))
        try:
            self.proc = subprocess.Popen(
                [os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
                 "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                 os.path.join(HERE, "engineer_speech.ps1"), phrase_file],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                text=True, encoding="utf-8", bufsize=1, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            set_priority(self.proc.pid)  # dictation and Zira yield to the game too
            ready = self.proc.stdout.readline().strip()
            self.ok = ready.startswith("READY")
            self.mic = "mic=True" in ready
            print("speech:", ready or "helper did not start")
        except OSError as e:
            print("speech helper failed:", e)

    def cmd(self, line):
        if not self.ok:
            return "ERR speech helper not running"
        with self.lock:
            self.proc.stdin.write(line.replace("\n", " ") + "\n")
            self.proc.stdin.flush()
            return self.proc.stdout.readline().strip()

    def listen(self):
        self.cmd("quiet")  # don't transcribe our own voice
        return self.cmd("listen")

    def stop(self):
        r = self.cmd("stop")
        return fix_transcript(r[5:].strip()) if r.startswith("TEXT") else ""

    def say(self, text):
        return self.cmd("say " + text)


WHISPER_PROMPT = ("Race engineer radio. Check car. Brakes? Radio check. How was my last lap? What's my best lap? Lap time, lap delta, sector. "
                  "Questions about corners by number, apex, hairpin, braking, trail braking, "
                  "throttle, tyres, tire pressures, brakes, engine temperature, fuel, damage, weather, debrief. "
                  "Requests: more front brake bias, FFB lighter, force feedback heavier, sport mode, traction control off, ESC on, "
                  "ABS off, launch control, center lock, undo that.")
WHISPER_HOTWORDS = "lap laps sector delta corner apex hairpin brakes tyres tires throttle debrief fuel engine coasting bias FFB ESC ABS traction"


# Words a recogniser hears instead of corner numbers ("corner for slow" is corner 4).
HOMOPHONES = {"for": "4", "fore": "4", "four": "4", "to": "2", "too": "2", "two": "2", "won": "1", "one": "1",
              "ate": "8", "eight": "8", "tree": "3", "free": "3", "three": "3", "sex": "6", "nein": "9"}


def fix_transcript(text):
    """Corner numbers as digits, and the usual mishearings around them."""
    def num(m):
        w = m.group(2).lower()
        return m.group(1) + HOMOPHONES[w] if w in HOMOPHONES else m.group(0)
    text = re.sub(r"\b(corners? )([a-zA-Z]+)\b", num, text, flags=re.I)
    text = re.sub(r"\bforce low\b", "4 slow", text, flags=re.I)  # "corner force low" = "corner four slow"
    text = re.sub(r"\bcorner 4 4 slow\b", "corner 4 slow", text, flags=re.I)
    text = re.sub(r"\bcorner (\d+) for slow\b", r"corner \1 slow", text, flags=re.I)
    # "break" for "brake" in braking talk (the two sound the same)
    text = re.sub(r"\bbreak(s|ing)?\b(?=\s+(better|later|earlier|harder|softer|sooner|point|points|bias|pressure|zone|marker|into|before))",
                  lambda m: {"s": "brakes", "ing": "braking"}.get((m.group(1) or "").lower(), "brake"), text, flags=re.I)
    return words_to_digits_corner(text)


def words_to_digits_corner(text):
    """'corner twelve' -> 'corner 12' (the rule-based answers and Haiku both read digits best)."""
    def rep(m):
        w = m.group(2).lower()
        return m.group(1) + (str(NUMBERS.index(w) + 1) if w in NUMBERS else m.group(2))
    return re.sub(r"\b(corners? )([a-zA-Z]+)\b", rep, text, flags=re.I)


WHISPER_REVIEW_EXTRA = (" Debrief questions: where did I lose time, corner 12, turn 5, lap 3, brake point, apex, exit speed, "
                        "trail braking, compare lap 2 with lap 4, consistency, theoretical best.")

# ---------------------------------------------------------------- voice log
# Every push-to-talk is kept for checking accuracy later (tools/voice_review.bat): the audio as a WAV, what
# Whisper heard with its confidence, and the engineer's answer. Local only (the game's settings folder).
# The newest voice_log_keep clips are kept (default 300, about 30 MB); 0 keeps no audio.
VOICE_LOG = os.path.join(DIR, "voicelog")
VOICE_LOG_FILE = os.path.join(VOICE_LOG, "log.jsonl")
FIXES_FILE = os.path.join(VOICE_LOG, "fixes.json")  # learned from your corrections by voice_review.py
_log_lock = threading.Lock()
_fixes = {"mtime": None, "pairs": [], "vocab": []}


def voice_log(rec):
    try:
        os.makedirs(VOICE_LOG, exist_ok=True)
        with _log_lock:
            if os.path.exists(VOICE_LOG_FILE) and os.path.getsize(VOICE_LOG_FILE) > 2_000_000:
                os.replace(VOICE_LOG_FILE, VOICE_LOG_FILE + ".old")
            with open(VOICE_LOG_FILE, "a", encoding="utf-8") as f:
                f.write(json.dumps(rec) + "\n")
    except OSError:
        pass


def save_clip(np, audio, name):
    """16 kHz mono WAV of what the mic heard; only the newest voice_log_keep clips stay."""
    keep = int(CONFIG.get("voice_log_keep", 300))
    if keep <= 0:
        return None
    import wave
    try:
        os.makedirs(VOICE_LOG, exist_ok=True)
        path = os.path.join(VOICE_LOG, name + ".wav")
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
        clips = sorted(f for f in os.listdir(VOICE_LOG) if f.endswith(".wav"))
        for old in clips[:-keep]:  # this log's own clips only
            os.remove(os.path.join(VOICE_LOG, old))
        return name + ".wav"
    except OSError:
        return None


def learned_fixes():
    """Phrase fixes and extra vocabulary learned from your corrections (re-read when the file changes)."""
    try:
        m = os.path.getmtime(FIXES_FILE)
    except OSError:
        return _fixes
    if m != _fixes["mtime"]:
        try:
            d = json.load(open(FIXES_FILE, encoding="utf-8"))
            _fixes.update(mtime=m, pairs=[(p["heard"], p["correct"]) for p in d.get("pairs", []) if p.get("heard") and p.get("on", True)],
                          vocab=[w for w in d.get("vocab", []) if isinstance(w, str)][:30])
        except (OSError, ValueError, KeyError, TypeError):
            _fixes["mtime"] = m
    return _fixes


def apply_learned(text):
    for heard, correct in learned_fixes()["pairs"]:
        text = re.sub(r"(?i)\b" + re.escape(heard) + r"\b", correct, text)
    return text


# Whisper's usual inventions on noise or silence
HALLUCINATIONS = {"thank you.", "thanks for watching!", "thank you for watching.", "you", "bye.", ".", "thanks."}


class WhisperListener:
    """Push-to-talk recording from the default microphone, transcribed by faster-whisper on the CPU.
    Two threads keep the game smooth (measured: about 3 fps lost while transcribing, for half a second).
    - Pre-roll: the mic stays open and the last half second before the key press is kept in memory (only
      that half second, never saved unless you talk), so the first word isn't clipped. mic_preroll: false
      opens the mic only while the key is held.
    - The audio is cleaned (rumble below about 100 Hz removed, level normalised) before Whisper hears it.
    - Low confidence: a second, wider search; noise or Whisper's usual inventions count as not heard."""

    def __init__(self):
        import collections
        import numpy as np
        import sounddevice as sd
        from faster_whisper import WhisperModel
        self.np, self.sd = np, sd
        self.model = WhisperModel(CONFIG["whisper"], device="cpu", compute_type="int8",
                                  cpu_threads=int(CONFIG["threads"]), download_root=MODELS)
        self.mic_name = sd.query_devices(kind="input")["name"]
        self.preroll = bool(CONFIG.get("mic_preroll", True))
        self.pre = collections.deque(maxlen=16)  # 16 blocks of 512 samples = about 0.5 s
        self.stream, self.chunks, self.recording, self.mode = None, [], False, "drive"
        if self.preroll:
            self._open()

    def _cb(self, data, frames, t, status):
        (self.chunks if self.recording else self.pre).append(data.copy())

    def _open(self):
        self.stream = self.sd.InputStream(samplerate=16000, channels=1, dtype="float32", blocksize=512, callback=self._cb)
        self.stream.start()

    def listen(self, mode="drive"):
        if self.recording:
            return "OK"
        self.mode = mode or "drive"
        if self.stream is None or not self.stream.active:  # first use, or the device went away
            try:
                if self.stream is not None:
                    self.stream.close()
            except Exception:
                pass
            self.pre.clear()
            self._open()
        self.chunks = list(self.pre)
        self.pre.clear()
        self.recording = True
        return "OK"

    def clean(self, a):
        np = self.np
        a = a - float(a.mean())
        k = 161  # 10 ms moving average: subtracting it removes rumble and wind below about 100 Hz
        if len(a) > k * 2:
            a = a - np.convolve(a, np.ones(k, dtype=np.float32) / k, mode="same")
        peak = float(np.abs(a).max()) if len(a) else 0
        if peak > 1e-4:
            a = a * min(0.9 / peak, 20.0)  # up to +26 dB for a quiet mic
        return a.astype(np.float32)

    def transcribe(self, audio, mode):
        fx = learned_fixes()
        prompt = WHISPER_PROMPT + (WHISPER_REVIEW_EXTRA if mode == "review" else "")
        if fx["vocab"]:
            prompt += " Also: " + ", ".join(fx["vocab"]) + "."
        hot = WHISPER_HOTWORDS + ((" " + " ".join(fx["vocab"])) if fx["vocab"] else "")

        def run(beam, temps):
            segs, _ = self.model.transcribe(audio, language="en", beam_size=beam, temperature=temps, initial_prompt=prompt,
                                            hotwords=hot, vad_filter=True, condition_on_previous_text=False, without_timestamps=True)
            segs = list(segs)
            text = " ".join(s.text.strip() for s in segs).strip()
            n = sum(max(1, len(s.text.split())) for s in segs) or 1
            lp = sum(s.avg_logprob * max(1, len(s.text.split())) for s in segs) / n if segs else -9.0
            return {"text": text, "logprob": round(lp, 3), "noSpeech": round(max((s.no_speech_prob for s in segs), default=1.0), 3),
                    "compression": round(max((s.compression_ratio for s in segs), default=0.0), 2)}

        r = run(3, 0.0)
        r["retried"] = False
        if r["text"] and (r["logprob"] < -0.7 or r["compression"] > 2.4):  # unsure: a wider search, keep the more confident
            r2 = run(5, (0.0, 0.2, 0.4))
            if r2["text"] and r2["logprob"] > r["logprob"]:
                r2["firstTry"] = r["text"]
                r = r2
            r["retried"] = True
        r["rejected"] = None
        low = r["text"].strip().lower()
        if low in HALLUCINATIONS and r["logprob"] < -0.5:
            r["rejected"] = "noise"
        elif r["noSpeech"] > 0.7 and r["logprob"] < -1.0:
            r["rejected"] = "unclear"
        return r

    def stop(self):
        if not self.recording:
            return ""
        time.sleep(0.25)  # keep the last word that was still being said on release
        self.recording = False
        chunks = self.chunks
        self.chunks = []
        if not self.preroll:
            try:
                self.stream.stop()
                self.stream.close()
            except Exception:
                pass
            self.stream = None
        if not chunks:
            return ""
        raw = self.np.concatenate(chunks)[:, 0]
        if len(raw) < 16000 * 0.3:
            return ""
        t0 = time.time()
        r = self.transcribe(self.clean(raw), self.mode)
        text = "" if r["rejected"] else apply_learned(fix_transcript(r["text"]))
        stt_secs = round(time.time() - t0, 2)
        uid = time.strftime("%Y%m%d_%H%M%S") + "_%03d" % int((time.time() % 1) * 1000)
        clip = save_clip(self.np, raw, uid)
        rec = {"type": "heard", "id": uid, "t": int(time.time()), "mode": self.mode, "wav": clip, "audioSecs": round(len(raw) / 16000, 2),
               "raw": r["text"], "text": text, "logprob": r["logprob"], "noSpeech": r["noSpeech"], "compression": r["compression"],
               "retried": r["retried"], "firstTry": r.get("firstTry"), "rejected": r["rejected"], "sttSecs": stt_secs,
               "model": CONFIG["whisper"], "peak": round(float(self.np.abs(raw).max()), 3)}
        voice_log(rec)
        LAST_HEARD.update(id=uid, text=text, t=time.time(), logprob=r["logprob"])
        return text


LAST_HEARD = {"id": None, "text": None, "t": 0, "logprob": None}  # links the next question to the clip it came from


# Styles: the engineer's personality and pace (the voices themselves are left untouched, so they stay smooth).
#   natural:    a straight, calm, professional race engineer (the only built-in style)
# "persona_prompt" in engineer_config.json replaces the style's personality text with your own.
STYLES = {
    "natural": {"pace": 1.0},
}

PERSONAS = {
    "natural": "",
}

# Added to a personality the user wrote, so it can't lose the facts or be unreadable aloud.
PERSONA_RULES = (" Whatever the personality, the engineering facts and numbers stay exact and useful, and the "
                 "length rules still apply. No emojis or stage directions; this is read aloud.")


def style_name():
    st = CONFIG.get("style", "natural")
    return st if st in STYLES else "natural"


def persona():
    """The personality added to every prompt: your own "persona_prompt" if set, otherwise the style's."""
    own = str(CONFIG.get("persona_prompt") or "").strip()
    return "\n\nPERSONALITY: " + own + PERSONA_RULES if own else PERSONAS[style_name()]


def flavour(text):
    """Hook for rule-based answers (kept plain)."""
    return text


def split_sentences(text):
    parts = [p.strip() for p in re.split(r"(?<=[.!?])\s+", text) if p.strip()]
    return parts or [text]


class KokoroSpeaker:
    """Kokoro, a natural-sounding local voice. Each answer is made sentence by sentence while the previous
    sentence plays, so speech starts after about 0.9 s (4 CPU threads; it only talks in the analysis)."""

    def __init__(self):
        import queue
        import numpy as np
        import onnxruntime as ort
        import sounddevice as sd
        from kokoro_onnx import Kokoro
        self.np, self.sd, self.queue = np, sd, queue
        so = ort.SessionOptions()
        so.intra_op_num_threads = int(CONFIG.get("tts_threads", 4))
        so.log_severity_level = 3
        sess = ort.InferenceSession(os.path.join(MODELS, "kokoro", "kokoro-v1.0.onnx"), so, providers=["CPUExecutionProvider"])
        self.k = Kokoro.from_session(sess, os.path.join(MODELS, "kokoro", "voices-v1.0.bin"))
        self.voice = CONFIG.get("kokoro_voice", "af_heart")
        self.lang = "en-gb" if self.voice.startswith("b") else "en-us"
        self.k.create("Ready.", voice=self.voice, lang=self.lang)  # warm up
        self.name = "%s, %s" % (self.voice, style_name())
        self.texts, self.audio = queue.Queue(), queue.Queue()
        self.gen = 0  # bumped by quiet(): drops anything made for an older answer
        threading.Thread(target=self._make, daemon=True).start()
        threading.Thread(target=self._play, daemon=True).start()

    def _make(self):
        while True:
            gen, text = self.texts.get()
            for sentence in split_sentences(text):
                if gen != self.gen:
                    break
                try:
                    speed = float(CONFIG.get("speed", 0.95)) * STYLES[style_name()]["pace"]
                    a, sr = self.k.create(sentence, voice=self.voice, speed=speed, lang=self.lang)
                    self.audio.put((gen, a.astype(self.np.float32) * float(CONFIG["volume"]), sr))
                except Exception as e:
                    print("voice failed:", e)

    def _play(self):
        while True:
            gen, a, sr = self.audio.get()
            if gen == self.gen:
                self.sd.play(a, sr)
                self.sd.wait()

    def say(self, text):
        self.texts.put((self.gen, text))
        return "OK"

    def quiet(self):
        self.gen += 1
        self.sd.stop()


class PiperSpeaker:
    """Piper, a lighter local voice (fallback). Lines queue up and play one after another."""

    def __init__(self):
        import queue
        import numpy as np
        import sounddevice as sd
        from piper import PiperVoice, SynthesisConfig
        self.np, self.sd = np, sd
        self.voice = PiperVoice.load(os.path.join(MODELS, "piper", CONFIG["voice"] + ".onnx"))
        self.cfg = lambda: SynthesisConfig(length_scale=1.0 / STYLES[style_name()]["pace"])
        self.name = "%s, %s" % (CONFIG["voice"], style_name())
        self.q = queue.Queue()
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        while True:
            text = self.q.get()
            try:
                sr = self.voice.config.sample_rate
                chunks = [c.audio_float_array for c in self.voice.synthesize(text, syn_config=self.cfg())]
                if chunks:
                    self.sd.play(self.np.concatenate(chunks) * float(CONFIG["volume"]), sr)
                    self.sd.wait()
            except Exception as e:
                print("voice failed:", e)

    def say(self, text):
        self.q.put(text)
        return "OK"

    def quiet(self):
        while not self.q.empty():
            self.q.get_nowait()
        self.sd.stop()


class Speech:
    """Best available speech-to-text and voice, falling back to Windows speech for either."""

    def __init__(self):
        self.win = WindowsSpeech()
        self.listener, self.speaker = None, None
        try:
            self.listener = WhisperListener()
            print("speech-to-text: Whisper %s on CPU (%s threads), mic: %s" % (CONFIG["whisper"], CONFIG["threads"], self.listener.mic_name))
        except Exception as e:
            print("speech-to-text: Windows dictation (Whisper unavailable: %s)" % e)
        engines = [("kokoro", KokoroSpeaker), ("piper", PiperSpeaker)]
        if CONFIG.get("tts") == "piper":
            engines.reverse()
        self.tts_engine = "windows"
        for name, cls in engines:
            try:
                self.speaker = cls()
                self.tts_engine = name
                print("voice: %s %s" % (name.capitalize(), self.speaker.name))
                break
            except Exception as e:
                print("voice: %s unavailable (%s)" % (name.capitalize(), e))
        if not self.speaker:
            print("voice: Windows")
        self.ok = self.win.ok or bool(self.speaker)
        self.mic = bool(self.listener) or self.win.mic
        self.stt_engine = "whisper" if self.listener else "windows"

    def listen(self, mode="drive"):
        self.quiet()  # don't transcribe our own voice
        return self.listener.listen(mode) if self.listener else self.win.listen()

    def stop(self):
        return self.listener.stop() if self.listener else self.win.stop()

    def say(self, text):
        return self.speaker.say(text) if self.speaker else self.win.say(text)

    def quiet(self):
        if self.speaker:
            self.speaker.quiet()
        self.win.cmd("quiet")


# ---------------------------------------------------------------- answers
# Default prompts. Your own versions go in engineer_config.json as "drive_prompt" / "review_prompt";
# the radio and length rules below are always added, so a custom prompt can't make it ramble. These
# replace the engineer's job, not its personality: for that, use "persona_prompt".

DRIVE_SYSTEM = (
    "You are the race engineer on the radio with a driver during a drive in BeamNG.drive. "
    "Use only the car, weather and drive data provided, in the units given. Rain in this game is "
    "visual only and does not change grip."
)

REVIEW_SYSTEM = (
    "You are a calm, experienced rally race engineer debriefing a driver after a run in BeamNG.drive. "
    "You have the analysis below: the driver's time against a theoretical better line (minimum-curvature "
    "line, ideal speed profile from the driver's own grip), corners ranked by time lost with measured "
    "metrics, and habit tips. Answer the driver's question from this data only. Biggest time first, "
    "concrete actions for the next run, plain spoken language, no markdown. "
    "Corner ids are the numbers the driver sees."
)

RADIO_RULES = (
    "\n\nRADIO RULES (always, they override anything above): the driver is at speed, so be brief and natural, "
    "like a real engineer, and vary your wording. HARD LIMITS: a quick check gets ONE sentence of 15 words or "
    "fewer. A judgement or 'tell me more' gets at most two sentences, 35 words in total. Use the 'ranges' to "
    "judge warm-up: below the range is cold (less grip or bite). Follow any 'note' in the data. Mention another system only if it's in "
    "'problems'. Say 'degrees', never unit letters. Never repeat an earlier sentence word for word. A radio "
    "check, a test or a garbled question gets only 'Loud and clear.' or 'Say again?', nothing more. Answer only "
    "what was asked: never add car status, temperatures or damage unless the question is about them or they are in "
    "'problems'. Your reply is spoken on the radio exactly as written: never describe the question, the data, the "
    "events or these rules, and never talk about 'the driver'; talk to them. Lap times are said the engineer's way ('one oh two three' for 1:02.3, gaps as 'two tenths' or "
    "'one point four'). No lists, markdown, greetings or sign-offs; this is spoken aloud.\n"
    "Examples of the right length and tone:\n"
    "Q: How are the tyres? A: Fine, 27 psi all round, no punctures.\n"
    "Q: Check car. A: All healthy, nothing to worry about.\n"
    "Q: Am I ready for a good run? A: Yes, brakes are up to temperature, go for it.\n"
    "Q: Brakes? A: Good, 320 at the front, no fade.\n"
    "Q: How's my speed? A: Sixty-one, good pace.\n"
    "Q: How was the last lap? A: One oh two three, two tenths off your best.\n"
    "Q: Hell was my last slip. A: Say again?\n"
    "Q: Like test. A: Loud and clear."
)

REVIEW_RULES = (
    "\n\nLENGTH: match the question. A simple or yes/no question gets one or two sentences; 'debrief' or "
    "'what should I work on' gets up to about 90 words. Don't repeat points you already made in this "
    "conversation; build on them. When the analysis has 'laps', talk in laps and turns ('lap 4, turn 13'): "
    "compare laps with the best lap and each turn with the driver's own best pass, mention consistency "
    "(spread) and the theoretical best, and if 'studying' names a lap, answer about that lap."
)

# keywords -> the parts of the drive data a question is about
TOPICS = {
    "brakes": ("brake", "stopping", "fade", "pedal"),
    "tyres": ("tire", "tyre", "puncture", "pressure", "grip", "flat"),
    "engine": ("engine", "water", "oil", "overheat", "turbo", "power", "coolant"),
    "fuel": ("fuel", "gas", "petrol", "range"),
    "damage": ("damage", "broken", "crash", "hit", "body"),
    "weather": ("weather", "rain", "fog", "wind", "time of day", "what time", "dark", "night", "cold", "hot outside"),
    "laps": ("lap", "best", "split", "delta", "sector", "fastest", "pb", "quicker", "slower", "how am i doing",
             "how did i do", "how was that", "pace", "faster"),
    "ready": ("ready", "warm", "temperature", "temps", "check car", "car check", "how's the car", "how is the car",
              "car ok", "condition", "status"),
    "setup": ("bias", "ffb", "force feedback", "adjustment", "setup", "brake strength", "mode", "esc", "traction control",
              "abs", "launch", "center lock", "centre lock", "changed"),
    "events": ("that corner", "last corner", "that turn", "last turn", "what happened", "just now", "back there", "crash",
               "that one", "how was that", "did i", "that hairpin", "that bend"),
}


def topics_of(q):
    q = q.lower()
    return [t for t, keys in TOPICS.items() if any(k in q for k in keys)]


# warm windows (Celsius): below = cold, above = overheating; converted to the driver's units
RANGES_C = {"tyres": (70, 105), "brakes": (150, 550), "engineWater": (80, 110)}


def car_problems(car):
    """Short phrases for anything that actually needs attention."""
    out = []
    b, t, e = car.get("brakes") or {}, car.get("tyres") or {}, car.get("engine") or {}
    if b.get("worstFade", 0) >= 15:
        out.append("brakes fading %d%%" % b["worstFade"])
    for w in t.get("flat") or []:
        out.append("puncture %s" % w)
    for w in t.get("broken") or []:
        out.append("%s wheel broken" % w)
    out += list(e.get("problems") or [])
    if car.get("fuel") is not None and car["fuel"] <= 15:
        out.append("fuel %d%%" % car["fuel"])
    dmg = car.get("damage") or {}
    if dmg.get("level") in ("moderate", "heavy"):
        parts = ", ".join(list(dmg.get("parts") or [])[:3])
        out.append("%s damage%s" % (dmg["level"], (" (" + parts + ")") if parts else ""))
    return out


def tyre_temp_simulated(d):
    """BeamNG only simulates tyre heat for some tyres: when the tyres sit at the air temperature
    (measured: 24.0 C on every tread node at speed after three hard laps, brakes at 300 C), they aren't."""
    car, wx = d.get("car") or {}, d.get("weather") or {}
    avg, air = (car.get("tyres") or {}).get("avg"), wx.get("temp")
    if avg is None or air is None:
        return avg is not None
    tol = 6 if car.get("tempUnit") == "F" else 3.5
    return abs(avg - air) > tol


def ranges_in(unit, tyres=True):
    conv = (lambda c: round(c * 9 / 5 + 32)) if unit == "F" else (lambda c: c)
    return {k: "%d-%d %s" % (conv(lo), conv(hi), unit) for k, (lo, hi) in RANGES_C.items() if tyres or k != "tyres"}


CAR_TOPICS = ("brakes", "tyres", "engine", "fuel", "damage")


def focus_drive(q, d):
    """What the question is about: those parts of the car (all of them for a car check), laps, weather
    or setup, plus anything that needs attention. Unasked systems stay out, so they don't end up in
    every answer."""
    car = d.get("car") or {}
    unit = car.get("tempUnit", "C")
    sim = tyre_temp_simulated(d)
    b, e, ty = car.get("brakes") or {}, car.get("engine") or {}, car.get("tyres") or {}
    c = {
        "brakes": b and {"front": b.get("front"), "rear": b.get("rear"), "fadePct": b.get("worstFade", 0)},
        "tyres": ty and {"avg": ty.get("avg") if sim else None, "pressure": ty.get("pressure") and "%s %s" % (ty["pressure"], car.get("pressureUnit", "psi")),
                         "flat": list(ty.get("flat") or [])},
        "engine": e and {"water": e.get("water"), "oil": e.get("oil"), "problems": list(e.get("problems") or [])},
        "fuelPct": car.get("fuel"),
        "damage": car.get("damage") and {"level": car["damage"].get("level"), "parts": list(car["damage"].get("parts") or [])[:4]},
    }
    asked = topics_of(q) or ["general"]
    want = [k for k in CAR_TOPICS if k in asked]
    if "ready" in asked or "setup" in asked:
        want = list(CAR_TOPICS)
    if "fuel" in want:
        want.append("fuelPct")
    problems = car_problems(car)
    out = {"askedAbout": asked, "tempUnit": unit, "problems": problems, "speed": d.get("speed")}
    if want:
        out["car"] = {k: v for k, v in c.items() if v not in (None, {}, []) and k in want}
        out["ranges"] = ranges_in(unit, sim)
    else:
        out["carStatus"] = "needs attention: " + ", ".join(problems) if problems else "healthy"
    if d.get("laps") and ("laps" in asked or "general" in asked):
        out["laps"] = d["laps"]
    if not sim and want:
        out["note"] = ("BeamNG does not simulate tyre temperature on this car: the tyres grip fully from cold and "
                       "never need warming, so never talk about tyre temperature. Only the brakes need heat "
                       "(below their range they bite less).")
    adj = d.get("adjust")
    if isinstance(adj, dict):  # what the driver has changed this drive (targets; 'waiting' = not applied yet)
        out["adjust"] = adjust_for_model(adj)
    if "weather" in out["askedAbout"]:
        out["weather"] = d.get("weather")
    if d.get("drive"):
        out["drive"] = d["drive"]
    if d.get("recent") and ("events" in asked or "laps" in asked or "general" in asked):
        out["recent"] = d["recent"]  # the last corners, crashes, laps and alerts, newest last
    return out


USAGE_LOG = os.path.join(DIR, "usage.jsonl")  # one line per Haiku call: tokens and time (no text)


def log_usage(out, secs, kind):
    u = out.get("usage") or {}
    line = {"t": int(time.time()), "kind": kind, "in": u.get("input_tokens"), "out": u.get("output_tokens"),
            "cacheRead": u.get("cache_read_input_tokens"), "cacheWrite": u.get("cache_creation_input_tokens"),
            "secs": round(secs, 2)}
    try:
        if os.path.exists(USAGE_LOG) and os.path.getsize(USAGE_LOG) > 1_000_000:  # keep about the last 10k calls
            os.replace(USAGE_LOG, USAGE_LOG + ".old")
        with open(USAGE_LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(line) + "\n")
    except OSError:
        pass


def haiku_call(system, messages, max_tokens=350, tools=None, tool_choice=None, cache=False, kind="drive", think=0):
    # no extended thinking by default: radio answers must be quick, and thinking would eat a short token
    # budget (Haiku 5.5 thinks by default and returned no text at all within 70-140 tokens). think: room
    # in tokens for a little thinking (adaptive, low effort; Haiku 5.5 takes no fixed budget), debriefs only.
    # cache: the system prompt (a review's whole analysis) is cached, so follow-up questions about the
    # same drive read it from the cache instead of paying for it again.
    # mid-drive answers think a little too (adaptive, low effort): without it Haiku 5.5 often drafts out loud
    # ("The driver asks...") or misreads a lap time; with it the 7 Haiku answers of tools/engineer_eval.py
    # were all clean, p50 2.1 s against 1.5 s. "drive_thinking": false in engineer_config.json for speed.
    if kind == "drive" and not think and CONFIG.get("drive_thinking", True):
        think, max_tokens = 1, max_tokens + 600
    sys_field = [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}] if cache else system
    body = {"model": MODEL, "max_tokens": max_tokens, "system": sys_field, "messages": messages,
            "thinking": {"type": "adaptive"} if think else {"type": "disabled"}}
    if think:
        body["output_config"] = {"effort": "low"}
    if tools:
        body["tools"], body["tool_choice"] = tools, tool_choice or {"type": "auto"}
    req = urllib.request.Request(API_URL, data=json.dumps(body).encode(), headers={
        "x-api-key": API_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=25) as r:
        out = json.load(r)
    log_usage(out, time.time() - t0, kind)
    return out


def text_of(out):
    text = "".join(b.get("text", "") for b in out.get("content", []) if b.get("type") == "text").strip()
    if out.get("stop_reason") == "max_tokens" and re.search(r"[.!?]", text[:-1]):
        text = re.match(r"(?s)(.*[.!?])", text).group(1)  # cut off: end on the last full sentence
    return text


def haiku(system, messages, max_tokens=350, cache=False, kind="drive"):
    return text_of(haiku_call(system, messages, max_tokens, cache=cache, kind=kind))


# ---------------------------------------------------------------- car adjustments
# What the driver can change mid-drive by asking: brake bias, brake strength, force feedback, and the
# car's own electronics where it has them (drive mode, ESC, traction control, ABS, launch control,
# AWD centre lock). The game (coDriverRec.lua) applies them on the next straight with the brake off,
# clamps them to the same limits, keeps them through resets for this car and this session, and drops
# them when the session ends or the car changes.
# Actions sent to the game: {"kind": ..., "value": ...} with kind bias / brake / ffb / awdLock (points
# or percent), launchRPM (rpm), esc / tc / abs / launch (true or false), driveMode (a mode key), or
# {"kind": "revert"}.

ADJ_LIMITS = {"bias": (-10, 10), "brake": (80, 110), "ffb": (60, 130), "awdLock": (0, 60), "launchRPM": (1500, 9000)}  # as coDriverRec.lua
ADJ_STEPS = {"bias": 2, "brake": 5, "ffb": 10, "awdLock": 10, "launchRPM": 500}
ADJ_STOCK = {"bias": 0, "brake": 100, "ffb": 100}
ADJ_FIELDS = {"bias": "biasShift", "brake": "brakePct", "ffb": "ffbPct"}
AID_NAMES = {"esc": "ESC", "tc": "traction control", "abs": "ABS", "launch": "launch control"}

TOOLS = [
    {"name": "set_brake_bias",
     "description": "Move the brake balance toward the front (positive) or the rear (negative). front_shift is the absolute target "
                    "in percentage points of total braking against the car's stock balance: 0 is stock, limits -10 to 10. Total "
                    "braking stays the same. Current target: data.adjust.biasShift.",
     "input_schema": {"type": "object", "properties": {"front_shift": {"type": "number", "description": "points toward the front, -10 to 10"}},
                      "required": ["front_shift"]}},
    {"name": "set_brake_strength",
     "description": "Overall brake strength (brake torque on every wheel) as an absolute percent of stock: 100 is stock, limits 80 "
                    "to 110. Current: data.adjust.brakePct.",
     "input_schema": {"type": "object", "properties": {"percent": {"type": "number", "description": "80 to 110"}}, "required": ["percent"]}},
    {"name": "set_ffb_strength",
     "description": "Steering-wheel force feedback strength as an absolute percent of the driver's own wheel setting: 100 is their "
                    "setting, lower is lighter, limits 60 to 130. Current: data.adjust.ffbPct.",
     "input_schema": {"type": "object", "properties": {"percent": {"type": "number", "description": "60 to 130"}}, "required": ["percent"]}},
    {"name": "set_drive_mode",
     "description": "Switch the car's drive mode, its own preset for ESC, traction control, throttle and the like. mode: one of "
                    "data.adjust.driveModes (current: data.adjust.driveMode). Only for cars that have drive modes.",
     "input_schema": {"type": "object", "properties": {"mode": {"type": "string"}}, "required": ["mode"]}},
    {"name": "set_driver_aids",
     "description": "Turn ESC (stability control), traction control or ABS on or off. Give only the ones the driver named. Only "
                    "those listed in data.adjust.has.",
     "input_schema": {"type": "object", "properties": {"esc": {"type": "boolean"}, "traction_control": {"type": "boolean"},
                                                       "abs": {"type": "boolean"}}}},
    {"name": "set_launch_control",
     "description": "Two-step launch control: enabled (on or off) and/or rpm, the launch rev limit from 1500 to "
                    "data.adjust.launchMaxRPM. Only if data.adjust.has includes launch.",
     "input_schema": {"type": "object", "properties": {"enabled": {"type": "boolean"}, "rpm": {"type": "number"}}}},
    {"name": "set_awd_lock",
     "description": "AWD centre coupling: the minimum lock between the front and rear axles, absolute percent 0 to 60. More lock "
                    "gives steadier traction out of slow corners and more understeer. Current: data.adjust.awdLockPct (missing = "
                    "the drive mode's own). Only if data.adjust.has includes awdLock.",
     "input_schema": {"type": "object", "properties": {"percent": {"type": "number", "description": "0 to 60"}}, "required": ["percent"]}},
    {"name": "revert_adjustments",
     "description": "Put everything back to stock: brake bias, brake strength, force feedback and the car's electronics.",
     "input_schema": {"type": "object", "properties": {}}},
]
TOOL_KINDS = {"set_brake_bias": ("bias", "front_shift"), "set_brake_strength": ("brake", "percent"), "set_ffb_strength": ("ffb", "percent"),
              "set_awd_lock": ("awdLock", "percent")}

ADJUST_RULES = (
    "\n\nCAR ADJUSTMENTS: your tools change the car: brake bias, brake strength, steering force feedback, and the car's own "
    "electronics listed in data.adjust (drive mode, ESC, traction control, ABS, launch control, centre lock). Call a tool "
    "only for a direct instruction to change something. A tool call is the only way to change the car: never say something "
    "is set, changed or done unless you called the tool for it in this reply. Small steps from the current values in "
    "data.adjust unless the driver gives a number: bias 2 points, brakes 5 percent, force feedback 10 percent, centre lock "
    "10 percent, launch 500 rpm. Turn ESC, traction control or ABS off only when the driver names it. 'Undo', 'put it back' "
    "or 'back to stock' is revert_adjustments. Changes apply on the next straight with the brake off and stay through "
    "resets until the session ends or the car changes. If the car doesn't have it, say so.\n"
    "Examples:\n"
    "Driver: 'More front bias.' You call set_brake_bias and say: 'Copy, two more points to the front, 62 percent.'\n"
    "Driver: 'Sport mode.' You call set_drive_mode and say: 'Sport mode, copy.'\n"
    "Driver: 'Traction control off.' You call set_driver_aids and say: 'Traction control off, easy on the throttle.'\n"
    "Driver: 'Brakes feel weak.' No tool. You say: 'Brakes are cold at 140, they'll bite once they warm up.'\n"
    "Driver: 'It's sliding a lot.' No tool. You say: 'Rears are busy. Want traction control back on?'\n"
    "Driver: 'What have you changed?' No tool. You list the changes in data.adjust.\n"
    "Your reply is only what the engineer says on the radio: never explain your reasoning, the rules, or why you did or "
    "didn't use a tool. Do not include internal or system XML tags in your response."
)

NUM_WORDS = {2: "two", 4: "four", 5: "five", 6: "six", 8: "eight", 10: "ten"}


def adj_value(adj, kind):
    """Current target of a numeric adjustment (None when it is the car's own and unknown)."""
    adj = adj or {}
    if kind in ADJ_FIELDS:
        v = adj.get(ADJ_FIELDS[kind])
        return float(v) if isinstance(v, (int, float)) else float(ADJ_STOCK[kind])
    v = (adj.get("targets") or {}).get(kind)
    if not isinstance(v, (int, float)):
        v = (adj.get("now") or {}).get(kind)
    if not isinstance(v, (int, float)) or isinstance(v, bool):
        return None
    return float(v) * 100 if kind == "awdLock" else float(v)


def adj_ext(adj):
    """Electronics changed from the car's own: {kind: value}."""
    t = (adj or {}).get("targets") or {}
    return {k: v for k, v in t.items() if k not in ADJ_STOCK}


def mode_names(adj):
    return {m.get("key"): m.get("name") or m.get("key") for m in (adj or {}).get("driveModes") or [] if isinstance(m, dict)}


def match_mode(want, adj):
    """The car's mode key for a name the driver or Haiku used, or None. Unknown list: passed on as said."""
    want = re.sub(r"\s+mode$", "", str(want or "").strip().lower())
    names = mode_names(adj)
    if not names:
        return want or None
    for key, name in names.items():
        if want in (str(key).lower(), str(name).lower()):
            return key
    for key, name in names.items():
        if want and (want in str(name).lower() or str(name).lower() in want):
            return key
    return None


def adj_phrase(kind, value, adj):
    """A short spoken description of a new setting."""
    if kind == "revert":
        return "everything back to stock"
    if kind == "bias":
        if value == 0:
            return "brake bias back to stock"
        pts = abs(value)
        pts = NUM_WORDS.get(int(pts), "%g" % pts) if pts == int(pts) else "%g" % pts
        s = "brake bias %s points %s" % (pts, "forward" if value > 0 else "rearward")
        stock = (adj or {}).get("stockFrontPct")
        return s + (", %d percent front" % round(stock + value)) if isinstance(stock, (int, float)) else s
    if kind in AID_NAMES:
        return "%s %s" % (AID_NAMES[kind], "on" if value else "off")
    if kind == "driveMode":
        return "%s mode" % mode_names(adj).get(value, value)
    if kind == "launchRPM":
        return "launch at %d rpm" % value
    if kind == "awdLock":
        return "centre lock at %g percent" % value
    return "%s at %g percent" % ("brakes" if kind == "brake" else "force feedback", value)


def clamp_num(kind, want, adj):
    lo, hi = ADJ_LIMITS[kind]
    if kind == "launchRPM" and isinstance((adj or {}).get("launchMaxRPM"), (int, float)):
        hi = adj["launchMaxRPM"]
    got = round(min(hi, max(lo, want)), 1 if kind != "launchRPM" else 0)
    return got, got != round(want, 1 if kind != "launchRPM" else 0), want > hi


def lacks(adj, cap):
    """True when the car is known not to have it."""
    return bool(adj) and (adj.get("has") or {}).get(cap) is False


APPLIES = " It applies on the next straight with the brake off."


def tool_action(name, inp, adj):
    """One tool call -> (actions for the game, result text for Haiku, limited flag)."""
    adj, inp = adj or {}, inp or {}
    if name == "revert_adjustments":
        if adj and all(adj_value(adj, k) == ADJ_STOCK[k] for k in ADJ_STOCK) and not adj_ext(adj):
            return [], "Nothing to undo: everything is already stock.", False
        return [{"kind": "revert"}], "Done: everything goes back to stock on the next straight.", False
    if name in TOOL_KINDS:
        kind, field = TOOL_KINDS[name]
        try:
            want = float(inp.get(field))
        except (TypeError, ValueError):
            return [], "No value given; nothing changed.", False
        if want != want:
            return [], "No value given; nothing changed.", False
        if kind == "bias" and adj.get("canBias") is False:
            return [], "This car has no separate front and rear brakes to balance; nothing changed.", False
        if kind == "awdLock" and lacks(adj, "awdLock"):
            return [], "This car has no adjustable AWD centre coupling; nothing changed.", False
        got, limited, high = clamp_num(kind, want, adj)
        text = "Done: " + adj_phrase(kind, got, adj)
        if limited:
            text += " (limited: %g is the %s)" % (got, "maximum" if high else "minimum")
        if kind == "ffb" and adj.get("ffbDevice") is False:
            text += ". No force feedback wheel is detected, so the driver may not feel it"
        return [{"kind": kind, "value": got}], text + "." + APPLIES, limited
    if name == "set_drive_mode":
        names = mode_names(adj)
        if adj and not names:
            return [], "This car has no drive modes; nothing changed.", False
        key = match_mode(inp.get("mode"), adj)
        if not key:
            return [], "This car has no mode called %r. Its modes: %s. Nothing changed." % (inp.get("mode"), ", ".join(names.values())), False
        return [{"kind": "driveMode", "value": key}], "Done: " + adj_phrase("driveMode", key, adj) + "." + APPLIES, False
    if name == "set_driver_aids":
        acts, missing = [], []
        for field, kind in (("esc", "esc"), ("traction_control", "tc"), ("abs", "abs")):
            val = inp.get(field)
            if isinstance(val, bool):
                if lacks(adj, kind):
                    missing.append(AID_NAMES[kind])
                else:
                    acts.append({"kind": kind, "value": val})
        text = ("Done: " + ", ".join(adj_phrase(a["kind"], a["value"], adj) for a in acts) + "." + APPLIES) if acts else "Nothing changed."
        if missing:
            text += " This car has no " + " or ".join(missing) + "."
        return acts, text, bool(missing)
    if name == "set_launch_control":
        if lacks(adj, "launch"):
            return [], "This car has no launch control; nothing changed.", False
        acts, limited = [], False
        if isinstance(inp.get("enabled"), bool):
            acts.append({"kind": "launch", "value": inp["enabled"]})
        try:
            rpm = float(inp.get("rpm"))
        except (TypeError, ValueError):
            rpm = None
        if rpm is not None and rpm == rpm:
            got, limited, high = clamp_num("launchRPM", rpm, adj)
            acts.append({"kind": "launchRPM", "value": got})
        if not acts:
            return [], "No value given; nothing changed.", False
        return acts, "Done: " + ", ".join(adj_phrase(a["kind"], a["value"], adj) for a in acts) + ("" if not limited else " (limited)") + "." + APPLIES, limited
    return [], "Unknown tool.", False


# a question about the car, not an instruction: "Should I turn off ABS?" is answered (with an offer),
# never acted on; "Can you turn off ABS?" and "Do it." stay requests
Q_START = re.compile(r"^\s*(what|what's|whats|how|is|are|am|was|were|did|does|do (i|you|we)|why|which|should|shall|would|"
                     r"will (it|that|i)|can i|could i|can you tell)\b")
P_UNDO = re.compile(r"\b(undo|put (it|them|that|everything|it all|the (bias|brakes|ffb|wheel|steering)) back|"
                    r"(go |set it |put it )?back to (stock|normal|default|standard)|revert|reset (the |my )?(changes|adjustments|setup|settings))\b")
P_BIAS_F = re.compile(r"\b((more|extra|add) (front|forward)( brake)? bias|(more )?bias (more )?(to the |towards the )?(front|forward)|"
                      r"(move|shift|put) (the )?(brake )?bias (forward|to the front|front|up)|less rear( brake)? bias)\b")
P_BIAS_R = re.compile(r"\b((more|extra|add) (rear|rearward)( brake)? bias|(more )?bias (more )?(to the |towards the )?(rear|back(wards)?)|"
                      r"(move|shift) (the )?(brake )?bias (back|rearward|to the rear|rear)|less front( brake)? bias)\b")
P_FFB_DOWN = re.compile(r"\bffb\b.*\b(lighter|lower|less|weaker|softer|down)\b|\b(lighter|less|lower|weaker|softer|reduce)\b.*\bffb\b|"
                        r"\b(lighter|softer) (steering|wheel)\b|\b(steering|wheel) (is |feels )?too (heavy|strong)\b|"
                        r"\bmake the (steering|wheel) lighter\b")
P_FFB_UP = re.compile(r"\bffb\b.*\b(heavier|higher|more|stronger|up)\b|\b(heavier|more|higher|stronger|increase)\b.*\bffb\b|"
                      r"\b(heavier|stronger) (steering|wheel)\b|\b(steering|wheel) (is |feels )?too (light|weak)\b|"
                      r"\bmake the (steering|wheel) heavier\b")
P_BRAKE_UP = re.compile(r"\b((more|stronger|harder) brak(es|ing)( power| force| pressure)?|more brake (power|force|pressure)|"
                        r"brakes? (are |feel )?too (weak|soft|light))\b")
P_BRAKE_DOWN = re.compile(r"\b((less|weaker|softer|lighter) brak(es|ing)( power| force| pressure)?|less brake (power|force|pressure)|"
                          r"brakes? (are |feel )?too (strong|grabby|sharp|touchy)|soften the brakes)\b")
AID_WORDS = r"(esc|stability control|traction control|tc|abs|launch control)"
P_AID = [re.compile(r"\b(?:turn|switch|put)\s+(on|off)\s+(?:the\s+)?" + AID_WORDS + r"\b"),
         re.compile(r"\b(?:turn|switch|put)\s+(?:the\s+)?" + AID_WORDS + r"\s+(on|off)\b"),
         re.compile(r"\b(disable|enable|kill)\s+(?:the\s+)?" + AID_WORDS + r"\b"),
         re.compile(r"(?:^|\b(?:and|,)\s+)" + AID_WORDS + r"\s+(?:to\s+)?(on|off)\b")]
AID_KIND = {"esc": "esc", "stability control": "esc", "traction control": "tc", "tc": "tc", "abs": "abs", "launch control": "launch"}
P_AWD_UP = re.compile(r"\b(more|stiffer|tighter|lock (up )?the) (centre|center)( diff| lock| coupling)?\b|\bmore (centre|center) lock\b")
P_AWD_DOWN = re.compile(r"\b(less|looser|softer|free up the|open (up )?the) (centre|center)( diff| lock| coupling)?\b")
P_LAUNCH_RPM = re.compile(r"\blaunch (?:control )?(?:rpm|revs?|at)\s*(?:to\s+)?(\d{4})\b")


def normalize_request(q):
    q = q.lower()
    q = re.sub(r"\bf\.?\s?f\.?\s?b\.?(?=\W|$)", "ffb", q)
    q = re.sub(r"\bforce(d)?[ -]?feed ?back\b", "ffb", q)
    q = re.sub(r"\be\.?\s?s\.?\s?c\.?(?=\W|$)", "esc", q)
    q = re.sub(r"\ba\.?\s?b\.?\s?s\.?(?=\W|$)", "abs", q)
    q = re.sub(r"\bt\.?\s?c\.?(?=\W|$)", "tc", q)
    return re.sub(r"\s+", " ", q).strip()


def offline_adjust(q, adj):
    """Rule-based car adjustment from simple phrases ('more front bias', 'ffb lighter', 'sport mode', 'tc off',
    'undo'). Returns (radio line, actions), or None when the question isn't a change request."""
    q = normalize_request(q)
    if Q_START.match(q):
        return None
    if P_UNDO.search(q):
        acts, _, _ = tool_action("revert_adjustments", {}, adj)
        return ("Copy, everything back to stock on the next straight." if acts else "Nothing to undo, it's all stock."), acts
    for pat, kind, sign in ((P_BIAS_F, "bias", 1), (P_BIAS_R, "bias", -1), (P_FFB_DOWN, "ffb", -1), (P_FFB_UP, "ffb", 1),
                            (P_BRAKE_DOWN, "brake", -1), (P_BRAKE_UP, "brake", 1), (P_AWD_UP, "awdLock", 1), (P_AWD_DOWN, "awdLock", -1)):
        if pat.search(q):
            name = {"bias": "set_brake_bias", "brake": "set_brake_strength", "ffb": "set_ffb_strength", "awdLock": "set_awd_lock"}[kind]
            now = adj_value(adj, kind)
            if now is None:
                now = 0.0
            acts, text, limited = tool_action(name, {TOOL_KINDS[name][1]: now + sign * ADJ_STEPS[kind]}, adj)
            if not acts:
                return text.split(";")[0].rstrip(".") + ".", []
            if limited and acts[0]["value"] == now:
                return "That's already the limit, %s." % adj_phrase(kind, acts[0]["value"], adj), []
            return "Copy, %s on the next straight." % adj_phrase(kind, acts[0]["value"], adj), acts
    m = P_LAUNCH_RPM.search(q)
    if m:
        acts, text, _ = tool_action("set_launch_control", {"rpm": float(m.group(1))}, adj)
        return ("Copy, %s." % adj_phrase("launchRPM", acts[0]["value"], adj)) if acts else text, acts
    for pat in P_AID:
        m = pat.search(q)
        if m:
            a, b = m.group(1), m.group(2)
            word, state = (b, a) if a in ("on", "off", "disable", "enable", "kill") else (a, b)
            kind, on = AID_KIND[word], state in ("on", "enable")
            if kind == "launch":
                acts, text, _ = tool_action("set_launch_control", {"enabled": on}, adj)
            else:
                acts, text, _ = tool_action("set_driver_aids", {{"esc": "esc", "tc": "traction_control", "abs": "abs"}[kind]: on}, adj)
            if not acts:
                return text.replace("Nothing changed. ", ""), []
            return "Copy, %s on the next straight." % adj_phrase(acts[0]["kind"], acts[0]["value"], adj), acts
    names = mode_names(adj)
    for key, name in sorted(names.items(), key=lambda kv: -len(str(kv[1]))):
        n = str(name).lower()
        if re.search(r"\b%s\b" % re.escape(n), q) and re.search(r"\bmode\b|\bswitch to\b|\bput it in\b|\bgo to\b", q):
            acts, _, _ = tool_action("set_drive_mode", {"mode": key}, adj)
            return "Copy, %s on the next straight." % adj_phrase("driveMode", key, adj), acts
    return None


def adjust_summary(adj):
    """Current adjustments in a few words, for the rule-based answers."""
    if not isinstance(adj, dict):
        return "no adjustments made"
    parts = []
    if adj_value(adj, "bias") != 0:
        parts.append(adj_phrase("bias", adj_value(adj, "bias"), adj))
    elif isinstance(adj.get("stockFrontPct"), (int, float)):
        parts.append("brake bias stock at %d percent front" % round(adj["stockFrontPct"]))
    for k in ("brake", "ffb"):
        if adj_value(adj, k) != 100:
            parts.append(adj_phrase(k, adj_value(adj, k), adj))
    for k, v in adj_ext(adj).items():
        parts.append(adj_phrase(k, v * 100 if k == "awdLock" else v, adj))
    return ", ".join(parts) + (", waiting for a straight" if adj.get("waiting") else "") if parts else "everything stock"


def adjust_for_model(adj):
    """The adjustment state in a compact form for Haiku."""
    out = {k: adj[k] for k in ("biasShift", "frontPct", "stockFrontPct", "brakePct", "ffbPct", "waiting", "canBias", "ffbDevice", "launchMaxRPM")
           if adj.get(k) is not None}
    names = mode_names(adj)
    if names:
        out["driveModes"] = list(names.values())
        out["driveMode"] = names.get(adj.get("driveMode"), adj.get("driveMode"))
    out["has"] = [k for k, v in (adj.get("has") or {}).items() if v]
    changed = {}
    for k, v in adj_ext(adj).items():
        if k == "awdLock":
            out["awdLockPct"] = round(v * 100)
        elif k == "launchRPM":
            changed["launch rpm"] = int(v)
        elif k == "driveMode":
            changed["drive mode"] = names.get(v, v)
        elif k in AID_NAMES:
            changed[AID_NAMES[k]] = "on" if v else "off"
    if changed:
        out["electronicsChanged"] = changed
    now, state = adj.get("now") or {}, {}
    for k in ("esc", "tc", "abs", "launch"):
        if isinstance(now.get(k), bool):
            state[AID_NAMES[k]] = "on" if now[k] else "off"
    if isinstance(now.get("launchRPM"), (int, float)) and now.get("launch") is not False:
        state["launch rpm"] = int(now["launchRPM"])
    if isinstance(now.get("awdLock"), (int, float)):
        state["centre lock percent"] = round(now["awdLock"] * 100)
        out.setdefault("awdLockPct", round(now["awdLock"] * 100))
    if state:
        out["electronicsNow"] = state
    return out


def drive_with_tools(system, msgs, adj, q=None, may_change=True):
    """A mid-drive answer that may change the car. Returns (text, actions). After a tool call Haiku is
    told the result and writes the radio line (its text next to the call is often a preamble). A clear
    change request answered without a tool call is asked again once, so it can't confirm a change it
    didn't make."""
    if not may_change:  # a question: answer it, and offer the change rather than make it
        out = haiku_call(system, msgs, max_tokens=160, tools=TOOLS, tool_choice={"type": "none"}, cache=True)
        return text_of(out), []
    out = haiku_call(system, msgs, max_tokens=160, tools=TOOLS, cache=True)
    uses = [b for b in out.get("content", []) if b.get("type") == "tool_use"]
    if not uses and q:
        hint = offline_adjust(q, adj)
        said = text_of(out)
        if hint and hint[1] and said:
            print("no tool call for a change request; asking again")
            msgs = msgs + [{"role": "assistant", "content": said},
                           {"role": "user", "content": "Nothing changed: you didn't call a tool. Make that change with the tool now."}]
            out = haiku_call(system, msgs, max_tokens=160, tools=TOOLS, cache=True)
            uses = [b for b in out.get("content", []) if b.get("type") == "tool_use"]
            if not uses:  # still none: the simple phrases make the change, so the line stays true
                return hint[0], hint[1]
    blocks = out.get("content", [])
    if not uses:
        return text_of(out), []
    actions, results, phrases, seen = [], [], [], set()
    for u in uses:
        if u.get("name") in seen:
            acts, res = [], "Already done in this reply."
        else:
            acts, res, _ = tool_action(u.get("name"), u.get("input"), adj)
        seen.add(u.get("name"))
        print("tool %s %s -> %s" % (u.get("name"), json.dumps(u.get("input")), res))
        for act in acts:
            actions.append(act)
            phrases.append(adj_phrase(act["kind"], act.get("value"), adj))
        results.append({"type": "tool_result", "tool_use_id": u.get("id"), "content": res})
    follow = msgs + [{"role": "assistant", "content": blocks}, {"role": "user", "content": results}]
    try:
        text = text_of(haiku_call(system, follow, max_tokens=110, tools=TOOLS, tool_choice={"type": "none"}))
    except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
        print("haiku follow-up failed:", e)
        text = ""
    if not text:
        text = ("Copy, " + " and ".join(phrases) + ".") if phrases else results[0]["content"]
    return text, actions


def words_to_digits(q):
    for i, w in enumerate(NUMBERS, 1):
        q = re.sub(r"\b%s\b" % w, str(i), q)
    return q


def offline_drive(q, d):
    """Rule-based radio answer: a short sentence about what was asked, with a warm-up verdict."""
    car, wx = d.get("car") or {}, d.get("weather") or {}
    unit = car.get("tempUnit", "C")
    cold = lambda c: (c - 32) * 5 / 9 if unit == "F" else c
    tops = topics_of(q)
    probs = car_problems(car)
    parts = []
    ty, b = car.get("tyres") or {}, car.get("brakes") or {}
    tyres_cold = tyre_temp_simulated(d) and ty.get("avg") is not None and cold(ty["avg"]) < RANGES_C["tyres"][0]
    brakes_cold = b.get("front") is not None and cold(b["front"]) < RANGES_C["brakes"][0]
    ready_q = any(k in q.lower() for k in ("ready", "good run", "warm", "condition"))
    for t in tops:
        if t == "brakes" and b:
            state = "fading" if b.get("worstFade", 0) >= 15 else ("still cold" if brakes_cold else "in the window")
            parts.append("brakes %s at %d degrees" % (state, b.get("front", 0)))
        elif t == "tyres" and ty:
            flats = list(ty.get("flat") or [])
            if flats:
                parts.append("puncture " + " and ".join(flats))
            elif not tyre_temp_simulated(d):
                parts.append("tyres fine, full grip" + (", %s %s" % (ty["pressure"], car.get("pressureUnit", "psi")) if ty.get("pressure") else ""))
            else:
                parts.append("tyres %s at %d degrees" % ("still cold" if tyres_cold else "up to temperature", ty.get("avg", 0)))
        elif t == "engine" and car.get("engine"):
            e = car["engine"]
            parts.append(("engine: " + ", ".join(list(e["problems"])[:2])) if e.get("problems") else "engine happy, water %d" % e.get("water", 0))
        elif t == "fuel" and car.get("fuel") is not None:
            parts.append("fuel at %d percent" % car["fuel"])
        elif t == "damage":
            dmg = car.get("damage") or {}
            where = ", ".join(str(p) for p in list(dmg.get("parts") or [])[:2])
            parts.append(("%s damage%s" % (dmg["level"], (", " + where) if where else "")) if dmg.get("level", "none") != "none" else "no real damage")
        elif t == "weather":
            parts.append("%s, %d degrees, %s%s" % (wx.get("time", ""), wx.get("temp", 0), wx.get("sky", ""), ", raining" if wx.get("rain") else ""))
        elif t == "setup":
            parts.append(adjust_summary(d.get("adjust")))
    if ready_q or not parts:
        if tyres_cold or brakes_cold:
            parts.append("%s still cold, give it a lap of hard braking first" % (
                "tyres and brakes" if tyres_cold and brakes_cold else ("tyres" if tyres_cold else "brakes")))
        elif probs:
            parts.append("watch the " + probs[0])
        elif not parts:
            parts.append("everything's in the window, go for it" if ready_q else "car's healthy")
    text = "; ".join(parts[:2])
    return text[0].upper() + text[1:] + "."


def offline_review(q, d):
    """Rule-based debrief from the analysis summary."""
    q = words_to_digits(q.lower())
    corners = {c.get("id"): c for c in d.get("corners") or []}
    m = re.search(r"corner\s*(\d+)", q) or (re.search(r"\b(\d+)\b", q) if "corner" in q else None)
    if m and int(m.group(1)) in corners:
        c = corners[int(m.group(1))]
        return "Corner %d: %s You lost %.1f seconds there." % (c["id"], c.get("note", ""), max(c.get("loss", 0), 0))
    if any(k in q for k in ("work on", "focus", "improve", "faster", "better", "tip")):
        tips = d.get("tips") or []
        return " ".join("%d. %s" % (i + 1, t.get("text", "")) for i, t in enumerate(tips[:3])) or "Not enough data yet."
    top = (d.get("corners") or [])[:3]
    s = "You were %.1f seconds off the better line." % d.get("gap", 0)
    if top:
        s += " Biggest losses: " + "; ".join("corner %d, %.1f s, %s" % (c["id"], max(c.get("loss", 0), 0), re.split(r"\.(?:\s|$)", c.get("note", ""))[0].lower()) for c in top) + "."
    return s


# ---------------------------------------------------------------- local answers and checks
# Simple status questions are answered here from the drive data with no API call (quicker, free, and
# never wrong about a number); so are radio checks, acknowledgements and speech too unsure to act on.
# Haiku's answers are checked before they're spoken: a reply that talks about the driver or the rules
# instead of to the driver, or that has a number the data doesn't have, gets one more try.

P_RADIO = re.compile(r"\b(radio check|mic check|comms check|can you hear me|do you (copy|read)( me)?|testing|test,? one|one,? two,? three|is this (thing )?(on|working))\b")
P_ACK = re.compile(r"^(ok(ay)?|thanks|thank you|cheers|copy( that)?|roger( that)?|got it|understood|will do|nice|good)[.!]?$")
P_OPEN = re.compile(r"\b(why|should|could|would|how (do|can|should) i|what (do|should|can) i|advice|tips?|better|faster|improve|compare|"
                    r"explain|tell me more|more detail|worth|think|recommend|help|where|which|lose|losing|lost)\b")
P_DOMAIN = re.compile(r"\b(car|cars|lap|laps|best|time|times|corner|corners|turn|turns|brake|brakes|braking|tyre|tyres|tire|tires|fuel|"
                      r"engine|damage|speed|fast|weather|rain|grip|line|sector|delta|gap|pace|bias|mode|esc|abs|traction|ffb|status|"
                      r"check|ready|temps?|temperature|water|oil|psi|pressure|puncture|crash|crashed|reset|setup|changed?|"
                      r"how was|how am i|how('s| is) the|what happened|what('s| is) my)\b")
P_LAST_LAP = re.compile(r"\b(last|previous|that) lap\b|\blap time\b")
P_BEST = re.compile(r"\b(my )?(best|fastest)( lap| time)?\b|\bpb\b")
P_LIVE = re.compile(r"\b(how am i doing|delta|am i up|am i down|up or down|on pace|current lap|this lap)\b")
P_SPEED = re.compile(r"\b(my )?speed\b|\bhow fast\b")
P_CHANGED = re.compile(r"\bwhat('s| have| did)? (you )?(changed?|set)\b|\bwhat('s| is) changed\b|\bcurrent (setup|settings)\b")
P_CAR_CHECK = re.compile(r"\b(check car|car check|how('s| is) the car|car ok|status( report)?|car status)\b")
LOW_CONFIDENCE = -0.55  # Whisper's average log probability below this: probably misheard (voice log, 2026-10-20)

SAY_AGAIN = "Say again?"
LOUD_AND_CLEAR = "Loud and clear."


def secs_of(t):
    """'1:02.27' or 62.27 -> 62.27"""
    if isinstance(t, (int, float)):
        return float(t)
    m = re.match(r"^\s*(?:(\d+):)?(\d+(?:\.\d+)?)\s*$", str(t or ""))
    return (int(m.group(1) or 0) * 60 + float(m.group(2))) if m else None


DIGIT_WORDS = ["oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]


def spoken_time(t):
    """62.27 -> 'one oh two point three' (as coDriverEngineer.lua says it at the line)"""
    t10 = int(round(t * 10))
    m, whole, tenth = t10 // 600, (t10 % 600) // 10, t10 % 10
    tenth_w = "zero" if tenth == 0 else DIGIT_WORDS[tenth]
    if m == 0:
        return "%d point %s" % (whole, tenth_w)
    secs = ("oh " + DIGIT_WORDS[whole]) if whole < 10 else str(whole)
    return "%s %s point %s" % (DIGIT_WORDS[m] if m < 10 else str(m), secs, tenth_w)


def spoken_gap(d, against="your best"):
    a = abs(d)
    if a < 0.05:
        return "same as " + against
    tenths = int(round(a * 10))
    amount = ("%s tenth%s" % (DIGIT_WORDS[tenths] if tenths < 10 else str(tenths), "" if tenths == 1 else "s")) if a < 1 else "%.1f" % a
    return amount + (" quicker" if d < 0 else " off " + against)


def local_laps(ql, laps):
    """Last lap, best lap or the running delta, from the lap timer's radio state; None if not that."""
    if not isinstance(laps, dict):
        return None
    cur, last, route = laps.get("current") or {}, laps.get("lastLap") or {}, laps.get("route") or {}
    if P_LIVE.search(ql) and cur:
        g = cur.get("gapToBestNow")
        if not cur.get("valid", True):
            return "Lap %s won't count, %s." % (cur.get("lap"), cur.get("notCountedBecause") or "it's invalid")
        if isinstance(g, (int, float)):
            return "%s, %d percent in." % (spoken_gap(g).capitalize(), cur.get("donePct", 0))
        return "Lap %s, no best to compare with yet." % cur.get("lap")
    if P_LAST_LAP.search(ql) and last:
        t = secs_of(last.get("time"))
        if t is None:
            return None
        if not last.get("valid", True):
            return "Lap %s, %s, not counted: %s." % (last.get("lap"), spoken_time(t), last.get("notCountedBecause") or "invalid")
        if last.get("newBest"):
            return "Lap %s, %s, new best." % (last.get("lap"), spoken_time(t))
        g = last.get("gapToBest")
        return "Lap %s, %s%s." % (last.get("lap"), spoken_time(t), (", " + spoken_gap(g)) if isinstance(g, (int, float)) else "")
    if P_BEST.search(ql) and not P_LAST_LAP.search(ql):
        b = secs_of(route.get("bestEver"))
        if b is None:
            return None
        return "Your best here is %s." % spoken_time(b)
    return None


def local_car_check(d):
    car = d.get("car") or {}
    probs = car_problems(car)
    if probs:
        return "Watch the %s." % " and the ".join(probs[:2])
    b = car.get("brakes") or {}
    unit = car.get("tempUnit", "C")
    front = b.get("front")
    if isinstance(front, (int, float)):
        c = (front - 32) * 5 / 9 if unit == "F" else front
        if c < RANGES_C["brakes"][0]:
            return "All healthy, brakes still cold at %d degrees." % front
        return "All healthy, brakes at %d, no fade." % front
    return "All healthy, nothing to worry about."


def local_answer(q, d, logprob=None, follow_up=False):
    """A radio answer that needs no API call, or None. logprob: Whisper's confidence when it was spoken.
    follow_up: the engineer spoke in the last minute, so a short reply ("Yes, go ahead.", "Pros and
    cons.", "OK") belongs to that conversation and goes to Haiku instead of "Say again?" or "Copy."."""
    ql = re.sub(r"\s+", " ", (q or "").lower()).strip()
    if not ql:
        return None
    words = len(ql.split())
    if P_RADIO.search(ql):
        return LOUD_AND_CLEAR
    if P_ACK.match(ql) and not follow_up:
        return "Copy."
    domain = bool(P_DOMAIN.search(ql)) or offline_adjust(q, d.get("adjust")) is not None
    unsure = logprob is not None and logprob < LOW_CONFIDENCE
    if not domain and P_OPEN.search(ql) and not unsure:
        return None  # "Any advice?", "Why?": short, but a real question for Haiku
    # misheard, or a short remark that isn't a question ("Guard image.", "I'm dead."); typed and
    # spoken questions ending in '?' still go to Haiku unless Whisper wasn't sure of them
    if not domain and (unsure or (words <= 3 and not ql.endswith("?") and not follow_up)):
        return SAY_AGAIN
    if offline_adjust(q, d.get("adjust")) is not None or P_OPEN.search(ql) or words > 8:
        return None  # a change to the car, or a question that needs thinking: Haiku
    lap = local_laps(ql, d.get("laps"))
    if lap:
        return lap
    if P_CHANGED.search(ql):
        return adjust_summary(d.get("adjust")).capitalize() + "."
    if P_SPEED.search(ql) and d.get("speed") and len(topics_of(ql)) == 0:
        n, unit = (str(d["speed"]).split() + [""])[:2]
        return "%s %s." % (n, {"mph": "miles an hour", "km/h": "kilometres an hour"}.get(unit, unit))
    if P_CAR_CHECK.search(ql):
        return local_car_check(d)
    tops = [t for t in topics_of(ql) if t in ("brakes", "tyres", "engine", "fuel", "damage", "weather")]
    if len(tops) == 1 and len(topics_of(ql)) == 1:
        return offline_drive(q, d)
    return None


P_LEAK = re.compile(r"\b(the driver|driver says|driver asks|driver's (question|request|message)|garbled|tool (call|request)|"
                    r"the (question|answer|rules|data says|system)|system prompt|as an ai|json|I('ll| will) (say|reply|respond)|"
                    r"(single|one|two) (short )?sentences?|\d+ words|judgement question|radio rules)\b", re.I)


def leaks(text):
    """The reply explains itself instead of being the radio line."""
    t = (text or "").strip()
    return bool(P_LEAK.search(t)) or t.startswith('"') or t.startswith("'")


def strip_leaks(text):
    """The reply without the sentences that explain it ('The driver asks... This is a judgement question...
    Brake a touch earlier.' -> 'Brake a touch earlier.'); '' if nothing is left."""
    keep = [s for s in split_sentences(re.sub(r"\s+", " ", text or "")) if not leaks(s)]
    return " ".join(keep).strip()


NUM_RE = re.compile(r"(?<![\w.])\d+(?:\.\d+)?")


def known_numbers(*objs):
    """Every number in the data and the question: plain numbers, and numbers inside strings (lap times
    '1:02.27' give 1, 2.27 and 62.27)."""
    out = set()

    def walk(o):
        if isinstance(o, bool) or o is None:
            return
        if isinstance(o, (int, float)):
            out.add(abs(float(o)))
        elif isinstance(o, str):
            for m in NUM_RE.finditer(o):
                out.add(float(m.group()))
            for m in re.finditer(r"(\d+):(\d+(?:\.\d+)?)", o):
                out.add(int(m.group(1)) * 60 + float(m.group(2)))
        elif isinstance(o, dict):
            for v in o.values():
                walk(v)
        elif isinstance(o, (list, tuple)):
            for v in o:
                walk(v)
    for o in objs:
        walk(o)
    return out


def unsupported_numbers(text, *data):
    """Numbers in an answer that aren't in the data (within rounding), nor a difference of two decimals in
    it (lap times, gaps). Small whole numbers pass: lap and turn numbers, steps, counts."""
    known = sorted(known_numbers(*data))
    decimals = [k for k in known if k != int(k)]
    bad = []
    for m in NUM_RE.finditer(text or ""):
        n = float(m.group())
        if n <= 10 and n == int(n):
            continue
        whole = "." not in m.group()
        tol = lambda k: max(0.051, abs(k) * 0.006) if not whole else 1.0
        if any(abs(n - k) < tol(k) for k in known):
            continue
        if not whole and len(decimals) < 800 and any(abs(abs(a - b) - n) < 0.051 for i, a in enumerate(decimals) for b in decimals[i + 1:]):
            continue
        bad.append(m.group())
    return bad


NUMBER_RETRY = "These numbers aren't in the data: %s. Answer again using only numbers from the data, just as short."
LEAK_RETRY = "Reply only with the words you say on the radio to the driver, nothing about the question or the rules."

# ---------------------------------------------------------------- review with tools (option)
# "review_tools": true in engineer_config.json. The analysis is about 13 KB (most of it corner details).
# With this the prompt gets a brief (the drive, the laps and an index of the costliest corners, 18% of
# it) and Haiku looks up the rest with these tools, which read the analysis the game sent with the
# question; each result is kept under 1.5 KB, and a debrief thinks a little first. Measured on the
# 7-lap drive (tools/engineer_eval.py, 10 questions): 27% fewer input tokens per question, but 66% more
# cost and p50 2.8 s against 1.6 s, because the whole analysis is cached after the first question and
# every tool round is a full call. So the default stays the whole analysis in the (cached) prompt.

REVIEW_TOOL_ROUNDS = 4
TOOL_BYTES = 1500

REVIEW_TOOLS = [
    {"name": "corner_detail",
     "description": "Measured details of up to 3 corners by id (from the corner index or 'selectedCorner'): speeds against the "
                    "better line, braking point, brake rise, coasting, throttle, apex, steering corrections, grip use, incident, "
                    "and the note.",
     "input_schema": {"type": "object", "properties": {"ids": {"type": "array", "items": {"type": "integer"}, "maxItems": 3}},
                      "required": ["ids"]}},
    {"name": "lap_detail",
     "description": "One lap: its time, gap to the best lap, sectors, the turns where it lost most against your best pass of each, "
                    "the stretches of road where it lost to the best lap (or, for the best lap, where other laps were quicker), "
                    "where it was quicker, and its costliest corners.",
     "input_schema": {"type": "object", "properties": {"lap": {"type": "integer"}}, "required": ["lap"]}},
    {"name": "lap_compare",
     "description": "Two laps turn by turn: each turn's time on both laps and the difference, the turns where lap a lost most "
                    "first, and the total gap.",
     "input_schema": {"type": "object", "properties": {"a": {"type": "integer"}, "b": {"type": "integer"}}, "required": ["a", "b"]}},
    {"name": "turn_detail",
     "description": "One turn of the lap (T1, T2...): its time on every lap, the best pass and on which lap, and the corners "
                    "measured there.",
     "input_schema": {"type": "object", "properties": {"turn": {"type": "integer"}}, "required": ["turn"]}},
]

REVIEW_TOOL_RULES = (
    "\n\nTOOLS: the brief below has the drive, the laps and an index of the costliest corners. Look details up with the "
    "tools before you talk about a corner, lap or turn in detail; quote numbers only from the brief or the tool results. "
    "Never mention the tools or the brief to the driver."
)


def clip_json(obj, limit=TOOL_BYTES):
    s = json.dumps(obj, separators=(",", ":"))
    while len(s) > limit and isinstance(obj, dict):
        biggest = max(obj, key=lambda k: len(json.dumps(obj[k])))
        v = obj[biggest]
        if isinstance(v, list) and len(v) > 1:
            obj = dict(obj, **{biggest: v[:max(1, len(v) // 2)]})
        else:
            obj = {k: x for k, x in obj.items() if k != biggest}
        s = json.dumps(obj, separators=(",", ":"))
    return s[:limit]


def review_brief(d):
    """What a review prompt carries: everything but the corner details and the per-turn and per-lap lists."""
    keys = ("session", "level", "unit", "driveSeconds", "betterLineSeconds", "gap", "gapWithoutIncidents", "incidents",
            "top3", "model", "selectedCorner", "tips", "weather")
    out = {k: d[k] for k in keys if d.get(k) not in (None, [], {})}
    corners = d.get("corners") or []
    out["cornerIndex"] = [{k: c.get(k) for k in ("id", "where", "dir", "loss", "incident") if c.get(k) not in (None, False)}
                          for c in corners[:12]]
    sel = d.get("selectedCorner")
    if sel and not any(c.get("id") == sel for c in corners[:12]):
        out["cornerIndex"] += [{k: c.get(k) for k in ("id", "where", "dir", "loss")} for c in corners if c.get("id") == sel]
    out["cornerIndexNote"] = "the %d costliest corners by time lost (of %d sent); corner_detail has the rest" % (min(12, len(corners)), len(corners))
    L = d.get("laps")
    if isinstance(L, dict):
        out["laps"] = {k: L.get(k) for k in ("bestLap", "theoreticalBest", "lapTimeStdDevS", "lengthKm", "studying") if L.get(k) is not None}
        out["laps"]["list"] = [{k: l.get(k) for k in ("lap", "time", "valid", "notCountedBecause", "gapToBest", "sectors") if l.get(k) is not None}
                               for l in L.get("laps") or []]
        out["laps"]["note"] = ("Turn numbers T1.. are the same place on every lap. Sectors are thirds of the lap. lap_detail, "
                               "lap_compare and turn_detail have where each lap lost time.")
    return out


def review_tool(name, inp, d):
    """-> a JSON string, under TOOL_BYTES"""
    inp = inp or {}
    corners = d.get("corners") or []
    L = d.get("laps") if isinstance(d.get("laps"), dict) else {}
    laps = {l.get("lap"): l for l in L.get("laps") or []}
    try:
        if name == "corner_detail":
            ids = [int(i) for i in (inp.get("ids") or [])][:3]
            found = [c for c in corners if c.get("id") in ids]
            return clip_json({"corners": found} if found else {"error": "no such corner among the %d sent" % len(corners)})
        if name == "lap_detail":
            n = int(inp.get("lap"))
            l = laps.get(n)
            if not l:
                return clip_json({"error": "no lap %d; laps are %s" % (n, sorted(laps))})
            own = [{k: c.get(k) for k in ("id", "where", "loss", "note")} for c in corners if str(c.get("where", "")).startswith("lap %d," % n)][:4]
            return clip_json(dict(l, costliestCorners=own))
        if name == "lap_compare":
            a, b = int(inp.get("a")), int(inp.get("b"))
            if a not in laps or b not in laps:
                return clip_json({"error": "laps are %s" % sorted(laps)})
            order = sorted(laps)
            ia, ib = order.index(a), order.index(b)
            rows = []
            for tn in L.get("turns") or []:
                ts = tn.get("timesByLap") or []
                if ia < len(ts) and ib < len(ts) and ts[ia] >= 0 and ts[ib] >= 0:
                    rows.append({"turn": tn.get("turn"), "dir": tn.get("dir"), "a": ts[ia], "b": ts[ib], "aLost": round(ts[ia] - ts[ib], 2)})
            rows.sort(key=lambda r: -r["aLost"])
            ta, tb = secs_of(laps[a].get("time")), secs_of(laps[b].get("time"))
            out = {"a": a, "b": b, "timeA": laps[a].get("time"), "timeB": laps[b].get("time"),
                   "gap": round(ta - tb, 2) if ta is not None and tb is not None else None, "turnsWhereALostMost": rows}
            if b == L.get("bestLap"):
                out["whereALostVsBestLap"] = laps[a].get("whereLostVsBestLap")
            return clip_json(out)
        if name == "turn_detail":
            n = int(inp.get("turn"))
            tn = next((t for t in L.get("turns") or [] if t.get("turn") == n), None)
            if not tn:
                return clip_json({"error": "no turn %d" % n})
            here = [{k: c.get(k) for k in ("id", "where", "loss", "note")} for c in corners if re.search(r"\bturn %d\b" % n, str(c.get("where", "")))][:4]
            return clip_json(dict(tn, lapsInOrder=sorted(laps), corners=here))
    except (TypeError, ValueError) as e:
        return clip_json({"error": "bad input: %s" % e})
    return clip_json({"error": "unknown tool"})


def is_debrief(q):
    return bool(re.search(r"\b(debrief|summary|sum up|overall|how did (i|that) go|what should i work on)\b", (q or "").lower()))


def review_with_tools(system, msgs, d, q):
    """Review answer with the lookup tools; a debrief thinks a little first. Returns the text."""
    think = 1024 if is_debrief(q) else 0
    rounds = 0
    while True:
        last = rounds >= REVIEW_TOOL_ROUNDS
        out = haiku_call(system, msgs, max_tokens=350 + think, tools=REVIEW_TOOLS, tool_choice={"type": "none"} if last else None,
                         cache=True, kind="review", think=think)
        uses = [b for b in out.get("content", []) if b.get("type") == "tool_use"]
        if not uses or last:
            return text_of(out)
        results = []
        for u in uses:
            res = review_tool(u.get("name"), u.get("input"), d)
            print("review tool %s %s -> %d bytes" % (u.get("name"), json.dumps(u.get("input")), len(res)))
            results.append({"type": "tool_result", "tool_use_id": u.get("id"), "content": res})
        msgs = msgs + [{"role": "assistant", "content": out.get("content")}, {"role": "user", "content": results}]
        rounds += 1


history = {"key": None, "turns": []}   # review conversation, per session
radio = {"turns": [], "t": 0}          # mid-drive conversation: kept for a few minutes so it doesn't repeat


def answer(req):
    """-> (text, source, actions for the game)"""
    q = (req.get("question") or "").strip()
    mode, data = req.get("mode", "drive"), req.get("data") or {}
    if not q:
        q = "Give me a short debrief." if mode == "review" else "Status report."
    offline = offline_review if mode == "review" else offline_drive
    if mode == "drive" and CONFIG.get("local_answers", True):
        spoken = LAST_HEARD["text"] and q == LAST_HEARD["text"] and time.time() - LAST_HEARD["t"] < 60
        follow = bool(radio["turns"]) and time.time() - radio["t"] < 60
        local = local_answer(q, data, LAST_HEARD.get("logprob") if spoken else None, follow_up=follow)
        if local:
            return local, "local", []

    def fallback(source):
        adj = offline_adjust(q, data.get("adjust")) if mode == "drive" else None
        return (adj[0], source, adj[1]) if adj else (flavour(offline(q, data)), source, [])

    if not API_KEY:
        return fallback("offline")
    actions, checked = [], None
    try:
        if mode == "review":
            key = data.get("session")
            if history["key"] != key:
                history["key"], history["turns"] = key, []
            msgs = history["turns"][-6:] + [{"role": "user", "content": q}]
            system = (CONFIG.get("review_prompt") or REVIEW_SYSTEM) + REVIEW_RULES + persona()
            if CONFIG.get("review_tools", False):
                system += REVIEW_TOOL_RULES + "\n\nBRIEF:\n" + json.dumps(review_brief(data), separators=(",", ":"))
                text = review_with_tools(system, msgs, data, q)
            else:
                system += "\n\nANALYSIS:\n" + json.dumps(data, separators=(",", ":"))
                text = haiku(system, msgs, cache=True, kind="review")
            bad = unsupported_numbers(text, data, q)
            if bad and text:
                print("numbers not in the analysis:", bad)
                retry = msgs + [{"role": "assistant", "content": text}, {"role": "user", "content": NUMBER_RETRY % ", ".join(bad)}]
                text = (review_with_tools(system, retry, data, q) if CONFIG.get("review_tools", False) else haiku(system, retry, cache=True, kind="review")) or text
                checked = "numbers"
            history["turns"] = msgs + [{"role": "assistant", "content": text}]
        else:
            if time.time() - radio["t"] > 180:
                radio["turns"] = []
            radio["t"] = time.time()
            focus = focus_drive(q, data)
            asking = bool(Q_START.match(q.lower()))
            payload = {"question": q, "data": focus}
            if asking:
                payload["note"] = ("This is a question, not an instruction: answer it and change nothing. If a change "
                                   "would help, offer it ('Want me to turn it off?').")
            msg = json.dumps(payload, separators=(",", ":"))
            msgs = radio["turns"][-6:] + [{"role": "user", "content": msg}]
            system = (CONFIG.get("drive_prompt") or DRIVE_SYSTEM) + persona() + RADIO_RULES + ADJUST_RULES
            text, actions = drive_with_tools(system, msgs, data.get("adjust"), q, may_change=not asking)
            said = [m["content"].strip().lower() for m in radio["turns"] if m["role"] == "assistant"]
            if text and not actions and text.strip().lower() in said:  # word-for-word repeat: ask once for fresh wording
                retry = msgs + [{"role": "assistant", "content": text},
                                {"role": "user", "content": "You said exactly that already. Same facts, different words, just as short."}]
                text = haiku(system, retry, max_tokens=110) or text
            if text and "\n\n" in text.strip():  # a draft, then the radio line: keep the last paragraph
                text = [p for p in re.split(r"\n\s*\n", text.strip()) if p.strip()][-1].strip()
            if text and not actions and leaks(text):  # talking about the question instead of answering it
                print("reply explains itself:", text[:120])
                checked = "leak"
                kept = strip_leaks(text)  # usually the last sentence is the radio line
                text = kept or haiku(system, msgs + [{"role": "assistant", "content": text}, {"role": "user", "content": LEAK_RETRY}], max_tokens=110)
                if not text or leaks(text):
                    text = SAY_AGAIN if not P_DOMAIN.search(q.lower()) else flavour(offline(q, data))
            if text and not actions:
                bad = unsupported_numbers(text, focus, q)
                if bad:
                    print("numbers not in the data:", bad)
                    checked = "numbers"
                    text = haiku(system, msgs + [{"role": "assistant", "content": text},
                                                 {"role": "user", "content": NUMBER_RETRY % ", ".join(bad)}], max_tokens=110) or text
            radio["turns"] = msgs + [{"role": "assistant", "content": text}]
        if not text:
            print("haiku returned no text")
            return fallback("offline (Haiku gave no text)")
        return text, "haiku" + ("+" + checked if checked else ""), actions
    except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
        detail = e.read().decode(errors="ignore")[:200] if isinstance(e, urllib.error.HTTPError) else str(e)
        print("haiku failed:", detail)
        return fallback("offline (Haiku unavailable)")


# ---------------------------------------------------------------- request loop

def voice_cover(text, words):
    """The game voicepack's phrases that say `text` word for word (greedy longest match, up to 4 words per
    phrase: 'nice save' -> ['nice_save']), or None when a word isn't recorded. Same rule as
    coDriverCoach.sayPhrase, which then plays them."""
    have = set(words or [])
    ws = re.findall(r"[a-z0-9]+", (text or "").lower().replace("'", ""))
    out, i = [], 0
    while ws and i < len(ws):
        for j in range(min(len(ws), i + 4), i, -1):
            key = "_".join(ws[i:j])
            if key in have:
                out.append(key)
                i = j
                break
        else:
            return None
    return out or None


def write_json(name, obj):
    tmp = os.path.join(DIR, "tmp_" + name)
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f)
    for attempt in range(20):  # the game may be reading the old file for a moment (Windows locks it)
        try:
            os.replace(tmp, os.path.join(DIR, name))
            return True
        except PermissionError:
            time.sleep(0.02)
    return False


def handle(speech, req):
    kind, rid = req.get("type"), req.get("id")
    if not re.fullmatch(r"[A-Za-z0-9_]{1,40}", str(rid)):  # the id names the reply file: nothing that leaves the folder
        print("request with a bad id dropped")
        return
    res = {"id": rid, "type": kind}
    try:
        if kind == "listen":
            r = speech.listen(req.get("mode"))
            res["ok"] = r == "OK"
            if not res["ok"]:
                res["error"] = r
        elif kind == "stop":
            res["text"] = speech.stop()
        elif kind == "ask":
            t0 = time.time()
            res["text"], res["source"], actions = answer(req)
            if actions:
                res["actions"] = actions
                print("actions:", json.dumps(actions))
            res["secs"] = round(time.time() - t0, 2)
            q = (req.get("question") or "").strip()
            spoken = LAST_HEARD["text"] and q == LAST_HEARD["text"] and time.time() - LAST_HEARD["t"] < 60
            voice_log({"type": "answer", "t": int(time.time()), "heard": LAST_HEARD["id"] if spoken else None, "mode": req.get("mode", "drive"),
                       "q": q, "a": res["text"], "source": res["source"], "secs": res["secs"], "actions": bool(actions)})
            if req.get("speak") and voice_cover(res["text"], req.get("voiceWords")):
                res["ownVoice"] = True  # every word is in the driver's own voicepack: the game says it
            elif req.get("speak") and speech.ok:
                speech.say(re.sub(r"[*_#`]", "", res["text"]))
        elif kind == "say":
            speech.say(req.get("text", ""))
        elif kind == "quiet":
            speech.quiet()
        else:
            res["error"] = "unknown request"
    except Exception as e:  # keep the bridge alive whatever happens
        res["error"] = str(e)
    write_json("res_%s.json" % rid, res)
    if kind in ("stop", "ask"):
        print("%s: %s" % (kind, res.get("text", res.get("error", ""))[:160]))


def main():
    os.makedirs(DIR, exist_ok=True)
    for old in glob.glob(os.path.join(DIR, "*_*.json")):  # leftovers from a previous run
        os.remove(old)
    print("Co-Driver engineer bridge")
    print("  priority:", CONFIG.get("priority", "below_normal"), "(set)" if set_priority() else "(unchanged)")
    print("  folder:", DIR)
    print("  answers:", "Claude Haiku (%s)" % MODEL if API_KEY else "rule-based (set ANTHROPIC_API_KEY for Haiku)")
    speech = Speech()
    last_beat, game_checked, game_on = 0, 0, True
    while True:
        # with the game closed (its heartbeat file over a minute old) poll once a second instead of 20 times;
        # no heartbeat file at all (an older mod) counts as running
        now = time.time()
        if now - game_checked > 2:
            game_checked = now
            was = game_on
            try:
                game_on = now - os.path.getmtime(GAME_BEAT) < 60
            except OSError:
                game_on = True
            if was != game_on:
                print("game", "running: listening fast" if game_on else "closed: polling slowly")
        try:
            last_beat = tick(speech, last_beat)
        except Exception as e:  # never let one bad moment stop the bridge
            print("loop error:", e)
        time.sleep(0.05 if game_on else 1.0)


def tick(speech, last_beat):
    """One pass: heartbeat, then any new requests."""
    now = time.time()
    if now - last_beat >= 1:
        last_beat = now
        write_json("bridge.json", {"t": int(now), "stt": speech.mic, "tts": speech.ok, "llm": bool(API_KEY),
                                   "model": MODEL, "sttEngine": speech.stt_engine, "ttsEngine": speech.tts_engine})
    for path in sorted(glob.glob(os.path.join(DIR, "req_*.json"))):
        try:
            with open(path, encoding="utf-8") as f:
                req = json.load(f)
            os.remove(path)
        except (OSError, ValueError):
            continue  # still being written
        if req.get("type") == "ask":  # Haiku can take a few seconds: answer in the background
            threading.Thread(target=handle, args=(speech, req), daemon=True).start()
        else:  # listen / stop / say stay in order
            handle(speech, req)
    return last_beat


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
