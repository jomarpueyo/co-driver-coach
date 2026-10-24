# Building your own co-driver voicepack

How the author's `custom` voicepack (120 clips of a recorded voice, not included in this repository) was made from two OBS recordings of
`phrases.txt` (the 120 lines of `VOICE_SCRIPT.md`, in order). Run the steps in order to record your own.

**Setup.**
- Python with numpy, soundfile and av (`pip install numpy soundfile av`).
- The steps share a work folder: `%TEMP%\cdc_tests`, or any folder you name in `CDC_VOICE_WORK`. Copy `phrases.txt` there first.
- Record yourself reading the script (any recorder that saves audio or video works).

1. `1_extract.py rec3=<take 1 file> rec4=<take 2 file>`: mono audio from the recordings (`rec3.wav`, `rec4.wav`) and the spoken segments.
   The take names are the ones the shipped take plan uses (step 4); with other takes, edit that plan and the names in `5_cut.py`.
2. `2_chunk.py rec3 rec4`: short chunks (up to about 4 s) cut at pauses, plus `chunks/index.json`.
3. `3_recognize.ps1`: Windows speech recognition of each chunk against the script lines
   (`chunks/recognized.json`).
4. `4_align.py`: matches segments to script lines (dynamic programming over recognition anchors and
   expected durations; a retake wins) and writes `alignment.json`. The take plan is at the bottom of the file: which take holds
   which lines (as shipped, `rec3` lines 1–78 and `rec4` lines 79–120 with a retake of 98–120). Edit it to match your takes.
5. `5_cut.py`: cuts the 120 clips, trims them to the voice, levels them to the game's clips, adds soft
   fades, and writes OGG clips and `metadata.json` (`voice_custom3/`) plus 16 kHz check WAVs.
6. `6_verify.ps1`: recognises each check WAV on its own and compares it with its line.
7. `7_master.py [target_dBFS]`: brings every clip to the same loudness (default -14 dBFS) with a soft
   limiter. Clip lengths don't change, so `metadata.json` stays valid.

Then copy `voice_custom3/` to `co_driver_coach/lua/ge/extensions/gameplay/rally/compositors/voicepacks/custom/`
and deploy. Clip names must not end in `_<digits>` (the loader treats those as alternate takes).
