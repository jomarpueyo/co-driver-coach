@echo off
rem Engineer voice review: what the engineer heard, how sure it was, and its answers (opens in your browser).
cd /d "%~dp0"
if exist ".venv\Scripts\python.exe" (".venv\Scripts\python.exe" voice_review.py) else (python voice_review.py)
pause
