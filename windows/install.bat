@echo off
rem PhotoAgent manual install (for developers / advanced users).
rem Most users should use PhotoAgent-Setup.exe from the Releases page instead.
title PhotoAgent manual install
cd /d "%~dp0"
echo.
echo  === PhotoAgent manual install ===
echo  (Recommended: download PhotoAgent-Setup.exe instead - no Python needed)
echo.

where py >nul 2>nul
if %errorlevel%==0 goto :have_python
where python >nul 2>nul
if %errorlevel%==0 goto :have_python

echo  Python not found. Installing via winget...
winget install -e --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements
if %errorlevel% neq 0 (
    echo  Automatic install failed. Please install Python from
    echo  https://www.python.org/downloads/ and run this file again.
    echo  IMPORTANT: check "Add python.exe to PATH" during setup.
    pause
    exit /b 1
)
echo  Python installed. Please close this window and run install.bat once more.
pause
exit /b 0

:have_python
echo  [1/2] Installing dependencies (first run only, 2-3 minutes)...
where py >nul 2>nul
if %errorlevel%==0 (
    py -3 -m pip install --quiet --user -r requirements.txt
) else (
    python -m pip install --quiet --user -r requirements.txt
)
if %errorlevel% neq 0 (
    echo  Download failed. Check your internet connection and try again.
    pause
    exit /b 1
)

echo  [2/2] Creating desktop shortcut...
powershell -NoProfile -Command ^
  "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Desktop')+'\PhotoAgent.lnk');" ^
  "$s.TargetPath='%~dp0run_photoagent.bat'; $s.WorkingDirectory='%~dp0'; $s.Save()"

echo.
echo  Done! Double-click the PhotoAgent shortcut on your desktop to start.
echo.
pause
