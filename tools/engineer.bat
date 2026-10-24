@echo off
rem Co-Driver Coach race engineer: voice questions, Haiku answers, spoken replies.
rem Leave this window open while you play. API key: tools\.anthropic_key (or ANTHROPIC_API_KEY).
rem Better voice and speech recognition: run engineer_setup.bat once.
title Co-Driver engineer
cd /d "%~dp0"
if exist ".venv\Scripts\python.exe" (
  ".venv\Scripts\python.exe" engineer.py
) else (
  python engineer.py
)
pause
