@echo off
chcp 65001 >nul
title PhotoAgent EXE 만들기
cd /d "%~dp0"
echo 배포용 단일 실행 파일(PhotoAgent.exe)을 만듭니다...
py -3 -m pip install --quiet pyinstaller
py -3 -c "from PIL import Image; Image.open('icon.png').save('icon.ico', sizes=[(16,16),(32,32),(48,48),(256,256)])"
py -3 -m PyInstaller --noconfirm --onefile --windowed --name PhotoAgent --icon icon.ico --add-data "icon.png;." photoagent_win.py
if %errorlevel%==0 (
    echo.
    echo 완료! dist\PhotoAgent.exe 파일 하나만 복사해서 쓰면 됩니다.
    echo (받는 사람 컴퓨터에 Python 이 없어도 실행돼요)
) else (
    echo 실패 — 먼저 설치.bat 를 실행했는지 확인하세요.
)
pause
