@echo off
rem One-time setup for the engineer's local speech: faster-whisper (speech-to-text) and Piper (voice).
rem Needs Python 3.10-3.12 (the py launcher picks 3.11 if installed). Downloads about 800 MB.
title Co-Driver engineer setup
cd /d "%~dp0"
py -3.11 -m venv .venv || python -m venv .venv
".venv\Scripts\python.exe" -m pip install --upgrade pip
".venv\Scripts\python.exe" -m pip install faster-whisper sounddevice piper-tts kokoro-onnx numpy
if not exist models\piper mkdir models\piper
for %%V in (en_GB/jenny_dioco/medium/en_GB-jenny_dioco-medium en_GB/cori/medium/en_GB-cori-medium en_US/kristin/medium/en_US-kristin-medium en_US/amy/medium/en_US-amy-medium) do (
  for %%E in (onnx onnx.json) do (
    if not exist "models\piper\%%~nxV.%%E" curl -sSL -o "models\piper\%%~nxV.%%E" "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/%%V.%%E"
  )
)
if not exist models\kokoro mkdir models\kokoro
for %%F in (kokoro-v1.0.onnx voices-v1.0.bin) do (
  if not exist "models\kokoro\%%F" curl -sSL -o "models\kokoro\%%F" "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/%%F"
)
".venv\Scripts\python.exe" -c "from faster_whisper import WhisperModel; WhisperModel('base.en', device='cpu', compute_type='int8', download_root='models'); print('Whisper ready')"
if not exist engineer_config.json copy engineer_config.example.json engineer_config.json >nul
echo Done. Start engineer.bat. Your preferences are in engineer_config.json.
pause
