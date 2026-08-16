@echo off
rem PhotoAgent for Windows 실행 스크립트
cd /d "%~dp0"
where py >nul 2>nul
if %errorlevel%==0 (
    py -3 photoagent_win.py %*
) else (
    python photoagent_win.py %*
)
