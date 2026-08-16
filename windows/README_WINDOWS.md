# PhotoAgent for Windows

사진 폴더를 고르면 흔들린 사진을 자동으로 걸러내고, 잘 나온 사진만 보정해서
새 폴더에 저장해 주는 프로그램입니다. **원본 사진은 절대 바뀌지 않습니다.**

## 설치 (권장: 인스톨러)

1. [Releases](https://github.com/EternaxCode/PhotoAgent/releases/latest) 에서 **`PhotoAgent-Setup.exe`** 다운로드
2. 더블클릭 → 설치 마법사 진행 (Python 등 아무것도 필요 없음)
   - SmartScreen 경고가 뜨면 **추가 정보 → 실행** (서명 인증서 미적용, 소스 공개됨)
3. 시작 메뉴 또는 바탕화면의 **PhotoAgent** 실행

인스톨러는 GitHub Actions 가 공개 소스에서 자동 빌드합니다
(`.github/workflows/build-windows.yml`).

### 수동 설치 (개발자용 대안)

Python 3.10+ 이 있다면: ZIP 압축 해제 → `install.bat` 더블클릭 →
바탕화면 바로가기 실행.

## 사용법 (3단계)

1. **① 사진 폴더 고르기** — 큰 파란 버튼을 누르고 사진이 든 폴더를 고르면
   자동으로 사진을 살펴봅니다.
2. **② 확인하기** — "잘 나온 사진 O장 / 흔들려 흐린 사진 O장" 요약이 보입니다.
   - 사진을 **한 번 클릭**하면 저장할지(초록)·뺄지(빨강)를 바꿀 수 있어요.
   - 원하면 **"사진에 이름/로고 넣기"** 를 켜고 문구·글씨체·위치를 꾸며 보세요.
   - **저장 크기**(원본/크게/보통/작게)와 **파일 형식**(JPG/PNG/WebP)도 고를 수 있어요.
     잘 모르겠으면 그대로 두면 됩니다.
3. **③ 저장하기** — "✨ 보정해서 저장하기"를 누르면 끝.
   완료되면 **"저장된 폴더 열기"** 버튼으로 결과를 바로 볼 수 있습니다.

저장 결과는 원래 폴더 옆에 `폴더이름_결과` 라는 새 폴더로 만들어집니다:
- `보정완료` — 보정된 사진
- `제외됨` — 흔들리거나 잘못 나온 사진 (사유별 정리)

## 배포용 EXE 만들기 (선택)

다른 사람에게 Python 설치 없이 나눠주고 싶으면 `build_exe.bat` 더블클릭 →
`dist\PhotoAgent.exe` 파일 하나만 복사해서 전달하면 됩니다.

## 전문가용 (터미널)

```bat
python photoagent_win.py --cli C:\사진폴더 --dry-run
python photoagent_win.py --cli C:\사진폴더 --watermark-text "© 홍길동" --max-edge 2048 --format webp
python photoagent_win.py --selftest
```

## Mac 버전과의 차이

판정 알고리즘(흔들림/초점/노출)과 워터마크는 동일. 사진별 정밀 편집·심도·영역
분리 보정은 Mac 전용 (Vision 프레임워크 의존).
