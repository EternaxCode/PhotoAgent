@echo off
rem PhotoAgent launcher (manual install)
cd /d "%~dp0"
where py >nul 2>nul
if %errorlevel%==0 (
    py -3 photoagent_win.py %*
) else (
    python photoagent_win.py %*
)
