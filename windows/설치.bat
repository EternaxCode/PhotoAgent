@echo off
chcp 65001 >nul
title PhotoAgent 설치
cd /d "%~dp0"
echo.
echo  ┌─────────────────────────────────────────┐
echo  │   PhotoAgent 설치를 시작합니다           │
echo  └─────────────────────────────────────────┘
echo.

rem 1) Python 확인
where py >nul 2>nul
if %errorlevel%==0 goto :have_python
where python >nul 2>nul
if %errorlevel%==0 goto :have_python

echo  Python 이 아직 없어서 자동으로 설치합니다. (1~2분 걸려요)
winget install -e --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements
if %errorlevel% neq 0 (
    echo.
    echo  자동 설치에 실패했습니다.
    echo  https://www.python.org/downloads/ 에서 Python 을 설치한 뒤
    echo  이 파일을 다시 실행해 주세요.
    echo  ※ 설치 화면에서 "Add python.exe to PATH" 를 꼭 체크하세요!
    pause
    exit /b 1
)
echo.
echo  Python 설치 완료! 이 창을 닫고 [설치.bat] 를 한 번 더 실행해 주세요.
pause
exit /b 0

:have_python
echo  [1/2] 필요한 프로그램을 내려받고 있어요... (처음 한 번만, 2~3분)
where py >nul 2>nul
if %errorlevel%==0 (
    py -3 -m pip install --quiet --user -r requirements.txt
) else (
    python -m pip install --quiet --user -r requirements.txt
)
if %errorlevel% neq 0 (
    echo  내려받기에 실패했습니다. 인터넷 연결을 확인하고 다시 실행해 주세요.
    pause
    exit /b 1
)

echo  [2/2] 바탕화면에 바로가기를 만들고 있어요...
powershell -NoProfile -Command ^
  "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Desktop')+'\PhotoAgent.lnk');" ^
  "$s.TargetPath='%~dp0run_photoagent.bat'; $s.WorkingDirectory='%~dp0'; $s.Save()"

echo.
echo  ┌─────────────────────────────────────────┐
echo  │   설치 완료!                             │
echo  │   바탕화면의 [PhotoAgent] 를 더블클릭    │
echo  │   하면 프로그램이 실행됩니다.            │
echo  └─────────────────────────────────────────┘
echo.
pause
