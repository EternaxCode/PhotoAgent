#!/usr/bin/env python3
"""PhotoAgent for Windows — 사진 자동 보정·정리 + 워터마크.

컴퓨터가 익숙하지 않아도 쓸 수 있는 3단계 마법사 UI:
  ① 사진 폴더 선택 → ② 결과 확인 → ③ 보정해서 저장

실행:
    python photoagent_win.py                 # GUI
    python photoagent_win.py --cli <폴더>    # 터미널 모드
    python photoagent_win.py --selftest      # 자가 검증
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, replace
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageOps

# ---------------------------------------------------------------------------
# 분석 (macOS 버전과 동일한 알고리즘·임계값)
# ---------------------------------------------------------------------------

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".tif", ".tiff", ".bmp", ".webp"}
ANALYSIS_MAX = 768
TILE_SIZE = 96
SUBJECT_THRESHOLD_SCALE = 2.0   # 타일 상위값은 전역 분산보다 높게 나옴
MOTION_ANISOTROPY = 2.5          # 이상 = 방향성 블러(흔들림)
DEFAULT_THRESHOLD = 45.0

VERDICT_GOOD = "양호"
VERDICT_BLURRY = "흔들림"
VERDICT_DEFOCUS = "초점불량"
VERDICT_DARK = "너무 어두움"
VERDICT_BRIGHT = "과노출"
VERDICT_FAILED = "분석 실패"

REJECT_FOLDER = {
    VERDICT_BLURRY: "흔들림",
    VERDICT_DEFOCUS: "초점불량",
    VERDICT_DARK: "어두움",
    VERDICT_BRIGHT: "과노출",
    VERDICT_FAILED: "분석실패",
    VERDICT_GOOD: "수동제외",
}

# 초보자용 쉬운 표현
EASY_VERDICT = {
    VERDICT_GOOD: ("잘 나온 사진", "#2e7d32"),
    VERDICT_BLURRY: ("흔들려 흐린 사진", "#c62828"),
    VERDICT_DEFOCUS: ("초점이 어긋난 사진", "#5c6bc0"),
    VERDICT_DARK: ("너무 어두운 사진", "#ef6c00"),
    VERDICT_BRIGHT: ("너무 밝은 사진", "#ef6c00"),
    VERDICT_FAILED: ("읽지 못한 사진", "#757575"),
}


@dataclass
class Metrics:
    sharpness: float
    tile_top: float
    tile_median: float
    anisotropy: float
    mean_luma: float
    clip_hi: float
    clip_lo: float
    width: int
    height: int

    @property
    def subject_sharpness(self) -> float:
        return self.tile_top


def load_rgb(path: Path) -> np.ndarray | None:
    """EXIF 방향 적용 + 한글 경로 안전 로드 (RGB uint8)."""
    try:
        with Image.open(path) as img:
            img = ImageOps.exif_transpose(img)
            return np.asarray(img.convert("RGB"))
    except Exception:
        return None


def analyze(path: Path) -> Metrics | None:
    rgb = load_rgb(path)
    if rgb is None:
        return None
    height, width = rgb.shape[:2]
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    scale = ANALYSIS_MAX / max(gray.shape)
    if scale < 1:
        gray = cv2.resize(gray, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    h, w = gray.shape
    if h < 3 or w < 3:
        return None

    gray_f = gray.astype(np.float64)
    lap = cv2.Laplacian(gray_f, cv2.CV_64F, ksize=1)  # 4-이웃 커널
    inner = lap[1:-1, 1:-1]
    global_var = float(inner.var())

    # 타일별 선명도 — 상위 2개 평균 / 중앙값
    tile_vars = []
    for ty in range(1, h - 1, TILE_SIZE):
        for tx in range(1, w - 1, TILE_SIZE):
            tile = lap[ty:min(ty + TILE_SIZE, h - 1), tx:min(tx + TILE_SIZE, w - 1)]
            if tile.shape[0] >= 48 and tile.shape[1] >= 48:
                tile_vars.append(float(tile.var()))
    tile_vars.sort()
    if len(tile_vars) >= 2:
        tile_top = (tile_vars[-1] + tile_vars[-2]) / 2
    elif tile_vars:
        tile_top = tile_vars[-1]
    else:
        tile_top = global_var
    tile_median = tile_vars[len(tile_vars) // 2] if tile_vars else global_var

    # gradient structure tensor — 블러 방향성 (흔들림 vs 초점)
    gx = cv2.Sobel(gray_f, cv2.CV_64F, 1, 0, ksize=3)
    gy = cv2.Sobel(gray_f, cv2.CV_64F, 0, 1, ksize=3)
    ixx = float((gx * gx).sum())
    iyy = float((gy * gy).sum())
    ixy = float((gx * gy).sum())
    trace = ixx + iyy
    disc = ((ixx - iyy) ** 2 + 4 * ixy * ixy) ** 0.5
    l1, l2 = (trace + disc) / 2, (trace - disc) / 2
    anisotropy = min(99.0, l1 / l2) if l2 > 1e-9 else 99.0

    mean_luma = float(gray.mean())
    total = gray.size
    clip_hi = float((gray >= 247).sum()) / total
    clip_lo = float((gray <= 8).sum()) / total

    return Metrics(global_var, tile_top, tile_median, anisotropy,
                   mean_luma, clip_hi, clip_lo, width, height)


def verdict_for(metrics: Metrics | None, threshold: float = DEFAULT_THRESHOLD) -> str:
    if metrics is None:
        return VERDICT_FAILED
    if metrics.mean_luma < 32 and metrics.clip_lo > 0.35:
        return VERDICT_DARK
    if metrics.mean_luma > 218 or metrics.clip_hi > 0.45:
        return VERDICT_BRIGHT
    if metrics.subject_sharpness < threshold * SUBJECT_THRESHOLD_SCALE:
        return VERDICT_BLURRY if metrics.anisotropy >= MOTION_ANISOTROPY else VERDICT_DEFOCUS
    return VERDICT_GOOD


def is_bokeh(metrics: Metrics, threshold: float = DEFAULT_THRESHOLD) -> bool:
    return (metrics.subject_sharpness >= threshold * SUBJECT_THRESHOLD_SCALE
            and metrics.tile_median < threshold * 0.8)


def auto_included(verdict: str) -> bool:
    """제외 대상은 흔들림·노출불량·분석실패 — 초점불량은 의도일 수 있어 포함."""
    return verdict in (VERDICT_GOOD, VERDICT_DEFOCUS)


# ---------------------------------------------------------------------------
# 자동 보정
# ---------------------------------------------------------------------------

def auto_enhance(rgb: np.ndarray) -> np.ndarray:
    """그레이월드 화이트밸런스(50%) + LAB CLAHE + 약한 채도 부스트."""
    img = rgb.astype(np.float32)
    means = img.reshape(-1, 3).mean(axis=0)
    gray_mean = means.mean()
    gains = np.clip(gray_mean / np.maximum(means, 1e-3), 0.8, 1.25)
    balanced = np.clip(img * (1 + (gains - 1) * 0.5), 0, 255).astype(np.uint8)

    lab = cv2.cvtColor(balanced, cv2.COLOR_RGB2LAB)
    clahe = cv2.createCLAHE(clipLimit=1.8, tileGridSize=(8, 8))
    lab[:, :, 0] = clahe.apply(lab[:, :, 0])
    enhanced = cv2.cvtColor(lab, cv2.COLOR_LAB2RGB)

    hsv = cv2.cvtColor(enhanced, cv2.COLOR_RGB2HSV).astype(np.float32)
    hsv[:, :, 1] = np.clip(hsv[:, :, 1] * 1.08, 0, 255)
    return cv2.cvtColor(hsv.astype(np.uint8), cv2.COLOR_HSV2RGB)


def unsharp(rgb: np.ndarray, strength: float) -> np.ndarray:
    """strength 0~100 → 언샤프 마스크."""
    if strength <= 0:
        return rgb
    amount = strength / 100 * 0.8
    blurred = cv2.GaussianBlur(rgb, (0, 0), sigmaX=1.6)
    return cv2.addWeighted(rgb, 1 + amount, blurred, -amount, 0)


# ---------------------------------------------------------------------------
# 워터마크 (Qt 텍스트 렌더링 — 시스템 폰트 사용)
# ---------------------------------------------------------------------------

ANCHORS = {
    "좌상": (0, 0), "상단": (1, 0), "우상": (2, 0),
    "좌측": (0, 1), "중앙": (1, 1), "우측": (2, 1),
    "좌하": (0, 2), "하단": (1, 2), "우하": (2, 2),
}


@dataclass
class WatermarkSettings:
    enabled: bool = False
    kind: str = "text"              # "text" | "image"
    text: str = "© PhotoAgent"
    font_family: str = ""           # 빈 값 = 시스템 기본
    size_percent: float = 4.0       # 긴 변 대비 %
    opacity: float = 0.7
    color: tuple = (255, 255, 255)
    anchor: str = "우하"
    margin_percent: float = 3.0
    image_path: str = ""
    image_scale_percent: float = 15.0

    def usable(self) -> bool:
        if self.kind == "text":
            return bool(self.text.strip())
        return bool(self.image_path) and Path(self.image_path).exists()


def _text_overlay_qt(settings: WatermarkSettings, long_edge: int) -> np.ndarray | None:
    """QPainter 로 텍스트 → RGBA numpy. QGuiApplication 필요."""
    from PySide6.QtCore import QPointF
    from PySide6.QtGui import QColor, QFont, QFontMetrics, QImage, QPainter

    px = max(8, int(settings.size_percent / 100 * long_edge))
    font = QFont(settings.font_family) if settings.font_family else QFont()
    font.setPixelSize(px)
    font.setBold(True)
    metrics = QFontMetrics(font)
    rect = metrics.boundingRect(settings.text)
    pad = int(px * 0.25)
    width = rect.width() + pad * 2
    height = rect.height() + pad * 2
    if width < 2 or height < 2:
        return None

    image = QImage(width, height, QImage.Format_RGBA8888)
    image.fill(0)
    painter = QPainter(image)
    painter.setRenderHint(QPainter.TextAntialiasing)
    painter.setFont(font)
    baseline = QPointF(pad - rect.left(), pad - rect.top())
    shadow = QColor(0, 0, 0, int(140 * settings.opacity))
    painter.setPen(shadow)
    painter.drawText(baseline + QPointF(px * 0.03, px * 0.05), settings.text)
    r, g, b = settings.color
    painter.setPen(QColor(int(r), int(g), int(b), int(255 * settings.opacity)))
    painter.drawText(baseline, settings.text)
    painter.end()

    ptr = image.constBits()
    arr = np.frombuffer(ptr, np.uint8).reshape(height, image.bytesPerLine())
    return arr[:, : width * 4].reshape(height, width, 4).copy()


def _logo_overlay(settings: WatermarkSettings, long_edge: int) -> np.ndarray | None:
    try:
        with Image.open(settings.image_path) as logo:
            rgba = np.asarray(logo.convert("RGBA"))
    except Exception:
        return None
    target_w = max(4, int(settings.image_scale_percent / 100 * long_edge))
    scale = target_w / rgba.shape[1]
    resized = cv2.resize(rgba, (target_w, max(1, int(rgba.shape[0] * scale))),
                         interpolation=cv2.INTER_AREA)
    resized = resized.copy()
    resized[:, :, 3] = (resized[:, :, 3].astype(np.float32) * settings.opacity).astype(np.uint8)
    return resized


def apply_watermark(rgb: np.ndarray, settings: WatermarkSettings) -> np.ndarray:
    if not settings.usable():
        return rgb
    H, W = rgb.shape[:2]
    long_edge = max(H, W)
    overlay = (_text_overlay_qt(settings, long_edge) if settings.kind == "text"
               else _logo_overlay(settings, long_edge))
    if overlay is None:
        return rgb
    h, w = overlay.shape[:2]
    margin = int(settings.margin_percent / 100 * long_edge)
    col, row = ANCHORS.get(settings.anchor, (2, 2))
    x = margin if col == 0 else ((W - w) // 2 if col == 1 else W - w - margin)
    y = margin if row == 0 else ((H - h) // 2 if row == 1 else H - h - margin)
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(W, x + w), min(H, y + h)
    if x1 <= x0 or y1 <= y0:
        return rgb
    ov = overlay[y0 - y : y1 - y, x0 - x : x1 - x].astype(np.float32)
    alpha = ov[:, :, 3:4] / 255.0
    out = rgb.copy()
    region = out[y0:y1, x0:x1].astype(np.float32)
    out[y0:y1, x0:x1] = (ov[:, :, :3] * alpha + region * (1 - alpha)).astype(np.uint8)
    return out


# ---------------------------------------------------------------------------
# 내보내기
# ---------------------------------------------------------------------------

# 내보내기 포맷: 표시명 → (Pillow 포맷, 확장자)
EXPORT_FORMATS = {
    "JPG": ("JPEG", ".jpg"),
    "PNG": ("PNG", ".png"),
    "WebP": ("WEBP", ".webp"),
}
# 내보내기 크기: 표시명 → 긴 변 픽셀 (0 = 원본 유지)
EXPORT_SIZES = [
    ("원본 크기 그대로", 0),
    ("크게 (4096px)", 4096),
    ("보통 (2048px)", 2048),
    ("작게 · 공유용 (1280px)", 1280),
]


def process_and_write(src: Path, dest: Path, enhance: bool, sharpen: float,
                      watermark: WatermarkSettings | None,
                      max_edge: int = 0, fmt: str = "JPG",
                      quality: int = 92) -> str | None:
    """성공 시 None, 실패 시 오류 문자열."""
    try:
        pillow_fmt, _ = EXPORT_FORMATS.get(fmt, EXPORT_FORMATS["JPG"])
        with Image.open(src) as pil:
            pil = ImageOps.exif_transpose(pil)
            exif = pil.info.get("exif")
            rgb = np.asarray(pil.convert("RGB"))
        if enhance:
            rgb = auto_enhance(rgb)
        rgb = unsharp(rgb, sharpen)
        # 크기 조절은 워터마크 전 — 워터마크가 결과 크기 기준 비율로 얹히도록
        if max_edge and max(rgb.shape[:2]) > max_edge:
            scale = max_edge / max(rgb.shape[:2])
            rgb = cv2.resize(rgb, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
        if watermark is not None:
            rgb = apply_watermark(rgb, watermark)
        dest.parent.mkdir(parents=True, exist_ok=True)
        out = Image.fromarray(rgb)
        options: dict = {}
        if pillow_fmt in ("JPEG", "WEBP"):
            options["quality"] = quality
            if exif:
                options["exif"] = exif
        out.save(dest, pillow_fmt, **options)
        return None
    except Exception as error:  # noqa: BLE001 — 리포트용
        return str(error)


def copy_reject(src: Path, dest: Path) -> str | None:
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)
        return None
    except Exception as error:  # noqa: BLE001
        return str(error)


def scan_images(folder: Path) -> list[Path]:
    return sorted(
        (p for p in folder.iterdir() if p.suffix.lower() in IMAGE_EXTS and p.is_file()),
        key=lambda p: p.name.lower(),
    )


def open_in_explorer(path: Path):
    if sys.platform == "win32":
        os.startfile(str(path))  # noqa: S606
    elif sys.platform == "darwin":
        subprocess.call(["open", str(path)])
    else:
        subprocess.call(["xdg-open", str(path)])


@dataclass
class Job:
    mode: str          # "enhance" | "copy"
    src: Path
    dest: Path
    watermark: WatermarkSettings | None = None


def run_jobs(jobs: list[Job], progress_cb=None, sharpen: float = 30,
             max_edge: int = 0, fmt: str = "JPG") -> list[str]:
    """내보내기 실행. 실패 목록 반환. GUI 스레드/스모크 양쪽에서 재사용."""
    failures: list[str] = []
    with ThreadPoolExecutor(max_workers=3) as pool:
        futures = {}
        for job in jobs:
            if job.mode == "enhance":
                futures[pool.submit(process_and_write, job.src, job.dest,
                                    True, sharpen, job.watermark,
                                    max_edge, fmt)] = job.src
            else:
                futures[pool.submit(copy_reject, job.src, job.dest)] = job.src
        done = 0
        for future in as_completed(futures):
            error = future.result()
            if error:
                failures.append(f"{futures[future].name}: {error}")
            done += 1
            if progress_cb:
                progress_cb(done, len(jobs))
    return failures


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def run_cli(args) -> int:
    source = Path(args.cli).expanduser()
    output = Path(args.out).expanduser() if args.out else source.parent / f"{source.name}_결과"
    threshold = args.threshold
    urls = scan_images(source)
    if not urls:
        print(f"이미지 없음: {source}")
        return 1
    print(f"분석 대상 {len(urls)}장 — {source}")

    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        results = list(pool.map(analyze, urls))

    counts: dict[str, int] = {}
    jobs: list[Job] = []
    for path, metrics in zip(urls, results):
        verdict = verdict_for(metrics, threshold)
        counts[verdict] = counts.get(verdict, 0) + 1
        tag = verdict
        if verdict == VERDICT_GOOD and metrics and is_bokeh(metrics, threshold):
            tag = "양호·아웃포커싱"
        subject = f"{metrics.subject_sharpness:8.1f}" if metrics else "       -"
        aniso = f"{metrics.anisotropy:5.1f}" if metrics else "    -"
        luma = f"{metrics.mean_luma:5.0f}" if metrics else "    -"
        print(f"  [{tag}] {path.name}  피사체{subject}  이방비{aniso}  휘도{luma}")
        if auto_included(verdict):
            jobs.append(Job("enhance", path, output / "보정완료" / f"{path.stem}.jpg"))
        else:
            jobs.append(Job("copy", path, output / "제외됨" / REJECT_FOLDER[verdict] / path.name))

    print("---")
    print(f"판정 요약 (임계값 {threshold}): "
          + " · ".join(f"{k} {v}" for k, v in counts.items()))
    if args.dry_run:
        print("dry-run — 파일을 쓰지 않았습니다")
        return 0

    if args.watermark_text:
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        from PySide6.QtGui import QGuiApplication
        if QGuiApplication.instance() is None:
            QGuiApplication([])
        watermark = WatermarkSettings(enabled=True, text=args.watermark_text)
        for job in jobs:
            if job.mode == "enhance":
                job.watermark = watermark

    print(f"내보내기 → {output}")
    fmt = {"jpg": "JPG", "png": "PNG", "webp": "WebP"}.get(args.format, "JPG")
    ext = EXPORT_FORMATS[fmt][1]
    for job in jobs:
        if job.mode == "enhance":
            job.dest = job.dest.with_suffix(ext)
    failures = run_jobs(jobs, sharpen=0 if args.no_sharpen else 30,
                        max_edge=args.max_edge, fmt=fmt)
    enhanced = sum(1 for j in jobs if j.mode == "enhance")
    print(f"완료 — 보정 {enhanced}장 · 제외 정리 {len(jobs) - enhanced}장 · 실패 {len(failures)}장")
    for failure in failures:
        print(f"  실패: {failure}")
    return 1 if failures else 0


# ---------------------------------------------------------------------------
# 셀프테스트
# ---------------------------------------------------------------------------

def run_selftest() -> int:
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    from PySide6.QtGui import QGuiApplication
    if QGuiApplication.instance() is None:
        QGuiApplication([])

    failed = False

    def check(condition: bool, message: str):
        nonlocal failed
        print(("PASS" if condition else "FAIL") + f": {message}")
        if not condition:
            failed = True

    rng = np.random.default_rng(7)
    noise = rng.integers(0, 256, (600, 800), dtype=np.uint8)
    noise_rgb = np.stack([noise] * 3, axis=-1)
    gaussian = cv2.GaussianBlur(noise_rgb, (0, 0), sigmaX=8)
    kernel = np.zeros((31, 31), np.float32)
    kernel[15, :] = 1 / 31
    motion = cv2.filter2D(noise_rgb, -1, kernel)
    dark = np.full((600, 800, 3), 6, np.uint8)
    bright = np.full((600, 800, 3), 252, np.uint8)

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)

        def save(arr, name):
            path = tmp_path / name
            Image.fromarray(arr).save(path, "JPEG", quality=95)
            return path

        cases = [
            (save(noise_rgb, "sharp.jpg"), VERDICT_GOOD, "선명한 노이즈"),
            (save(gaussian, "gaussian.jpg"), VERDICT_DEFOCUS, "가우시안 블러 → 초점불량"),
            (save(dark, "dark.jpg"), VERDICT_DARK, "암부"),
            (save(bright, "bright.jpg"), VERDICT_BRIGHT, "명부"),
        ]
        for path, expected, label in cases:
            metrics = analyze(path)
            verdict = verdict_for(metrics)
            subject = f"{metrics.subject_sharpness:.1f}" if metrics else "-"
            check(verdict == expected, f"{label} → {verdict} (기대 {expected}, 피사체 {subject})")

        gaussian_aniso = analyze(save(gaussian, "g2.jpg")).anisotropy
        motion_aniso = analyze(save(motion, "m2.jpg")).anisotropy
        check(gaussian_aniso < 2.0, f"가우시안 이방비 {gaussian_aniso:.2f} < 2.0 (등방)")
        check(motion_aniso >= MOTION_ANISOTROPY, f"모션 이방비 {motion_aniso:.2f} ≥ 2.5 (방향성)")

        dim = np.full((300, 400, 3), 60, np.uint8)
        check(auto_enhance(dim).mean() > dim.mean() + 2, "자동 보정 → 휘도 상승")

        gray_img = np.full((600, 800, 3), 102, np.uint8)
        wm = WatermarkSettings(enabled=True, text="© TEST WATERMARK",
                               size_percent=5, opacity=1, anchor="우하", margin_percent=2)
        marked = apply_watermark(gray_img, wm)
        corner = marked[520:590, 480:790].mean()
        center = marked[250:350, 300:500].mean()
        check(corner > 104 and abs(center - 102) < 1,
              f"텍스트 워터마크 — 우하단 102→{corner:.0f}, 중앙 {center:.0f} 유지")

        logo_path = tmp_path / "logo.png"
        Image.fromarray(np.full((100, 200, 3), 255, np.uint8)).save(logo_path)
        logo_wm = WatermarkSettings(enabled=True, kind="image", image_path=str(logo_path),
                                    image_scale_percent=20, opacity=1,
                                    anchor="좌상", margin_percent=2)
        logo_marked = apply_watermark(gray_img, logo_wm)
        check(logo_marked[20:90, 20:150].mean() > 200, "이미지 로고 워터마크 — 좌상단 합성")

        out = tmp_path / "out.jpg"
        error = process_and_write(save(noise_rgb, "src.jpg"), out, True, 30, wm)
        check(error is None and out.exists() and analyze(out) is not None,
              "보정+워터마크 파이프라인 (out.jpg 생성·재분석)")

        # 크기·포맷 내보내기
        resized_out = tmp_path / "resized.png"
        error = process_and_write(save(noise_rgb, "src2.jpg"), resized_out,
                                  True, 0, None, max_edge=500, fmt="PNG")
        with Image.open(resized_out) as resized:
            ok = (error is None and resized.format == "PNG"
                  and max(resized.size) == 500)
            check(ok, f"크기·포맷 내보내기 — PNG {resized.size[0]}×{resized.size[1]} (긴 변 500)")

        webp_out = tmp_path / "small.webp"
        error = process_and_write(save(noise_rgb, "src3.jpg"), webp_out,
                                  True, 0, None, max_edge=300, fmt="WebP")
        with Image.open(webp_out) as webp_img:
            check(error is None and webp_img.format == "WEBP" and max(webp_img.size) == 300,
                  f"WebP 내보내기 — {webp_img.size[0]}×{webp_img.size[1]}")

    print("SELFTEST FAILED" if failed else "SELFTEST OK")
    return 1 if failed else 0


# ---------------------------------------------------------------------------
# GUI — 3단계 마법사 (초보자용)
# ---------------------------------------------------------------------------

STYLESHEET = """
QWidget { font-size: 13px; }
QLabel#title { font-size: 26px; font-weight: bold; }
QLabel#subtitle { font-size: 15px; color: #555; }
QLabel#stepOn { font-size: 15px; font-weight: bold; color: #2f6fed;
                padding: 8px 18px; border-bottom: 3px solid #2f6fed; }
QLabel#stepOff { font-size: 15px; color: #999; padding: 8px 18px; }
QLabel#summary { font-size: 17px; font-weight: bold; }
QLabel#hint { font-size: 13px; color: #777; }
QPushButton#primary { background: #2f6fed; color: white; font-size: 17px;
                      font-weight: bold; padding: 14px 34px; border-radius: 10px; border: none; }
QPushButton#primary:hover { background: #2456c4; }
QPushButton#primary:disabled { background: #a9c0ef; }
QPushButton#secondary { font-size: 14px; padding: 10px 22px; border-radius: 8px; }
QListWidget { background: #f4f5f7; border: none; }
"""


def run_gui(smoke: bool = False, smoke_folder: str | None = None) -> int:
    from PySide6.QtCore import Qt, QSize, Signal, QObject
    from PySide6.QtGui import QColor, QIcon, QImage, QImageReader, QPixmap
    from PySide6.QtWidgets import (
        QApplication, QCheckBox, QColorDialog, QComboBox, QDialog, QDoubleSpinBox,
        QFileDialog, QFontComboBox, QFormLayout, QGridLayout, QGroupBox, QHBoxLayout,
        QLabel, QLineEdit, QListWidget, QListWidgetItem, QMenu, QProgressBar,
        QPushButton, QRadioButton, QSlider, QStackedWidget, QVBoxLayout, QWidget,
    )

    class Bridge(QObject):
        progress = Signal(int, int, str)
        finished = Signal(str)

    # ---- 워터마크 꾸미기 대화상자 ----

    class WatermarkDialog(QDialog):
        def __init__(self, window: "MainWindow"):
            super().__init__(window)
            self.window = window
            self.setWindowTitle("사진에 넣을 이름/로고 꾸미기")
            self.resize(920, 560)
            wm = window.watermark

            layout = QHBoxLayout(self)
            self.preview_label = QLabel("미리보기")
            self.preview_label.setMinimumSize(480, 400)
            self.preview_label.setAlignment(Qt.AlignCenter)
            self.preview_label.setStyleSheet("background:#111; color:#888; border-radius:8px;")
            layout.addWidget(self.preview_label, 1)

            panel = QVBoxLayout()
            guide = QLabel("저장할 사진 위에 이름이나 로고를 넣어요.\n미리보기를 보면서 자유롭게 바꿔 보세요.")
            guide.setObjectName("hint")
            panel.addWidget(guide)

            form = QFormLayout()
            self.kind_combo = QComboBox()
            self.kind_combo.addItems(["글자 넣기", "로고 그림 넣기"])
            self.kind_combo.setCurrentIndex(0 if wm.kind == "text" else 1)
            form.addRow("종류", self.kind_combo)

            self.text_edit = QLineEdit(wm.text)
            self.text_edit.setPlaceholderText("예: © 홍길동 사진관")
            form.addRow("넣을 글자", self.text_edit)

            self.font_combo = QFontComboBox()
            if wm.font_family:
                self.font_combo.setCurrentText(wm.font_family)
            form.addRow("글씨체", self.font_combo)

            self.size_spin = QDoubleSpinBox()
            self.size_spin.setRange(1, 15)
            self.size_spin.setSuffix(" (크기)")
            self.size_spin.setValue(wm.size_percent)
            form.addRow("글자 크기", self.size_spin)

            self.color_button = QPushButton("색 고르기…")
            self.color_button.clicked.connect(self.choose_color)
            form.addRow("글자 색", self.color_button)

            self.logo_button = QPushButton(
                Path(wm.image_path).name if wm.image_path else "로고 그림 파일 고르기…")
            self.logo_button.clicked.connect(self.choose_logo)
            form.addRow("로고 그림", self.logo_button)

            self.logo_scale = QDoubleSpinBox()
            self.logo_scale.setRange(3, 50)
            self.logo_scale.setValue(wm.image_scale_percent)
            form.addRow("로고 크기", self.logo_scale)

            self.opacity_spin = QDoubleSpinBox()
            self.opacity_spin.setRange(0.05, 1.0)
            self.opacity_spin.setSingleStep(0.05)
            self.opacity_spin.setValue(wm.opacity)
            form.addRow("진하기", self.opacity_spin)

            self.margin_spin = QDoubleSpinBox()
            self.margin_spin.setRange(0, 10)
            self.margin_spin.setValue(wm.margin_percent)
            form.addRow("가장자리 여백", self.margin_spin)
            panel.addLayout(form)

            anchor_box = QGroupBox("어느 자리에 넣을까요?")
            grid = QGridLayout(anchor_box)
            self.anchor_buttons = {}
            for name, (col, row) in ANCHORS.items():
                radio = QRadioButton(name)
                radio.setChecked(name == wm.anchor)
                radio.toggled.connect(self.refresh)
                grid.addWidget(radio, row, col)
                self.anchor_buttons[name] = radio
            panel.addWidget(anchor_box)

            done = QPushButton("완료")
            done.setObjectName("primary")
            done.clicked.connect(self.accept)
            panel.addWidget(done)
            panel.addStretch()
            layout.addLayout(panel)

            self._color = wm.color
            self.text_edit.textChanged.connect(self.refresh)
            self.kind_combo.currentIndexChanged.connect(self.refresh)
            self.font_combo.currentFontChanged.connect(self.refresh)
            for spin in (self.size_spin, self.opacity_spin, self.margin_spin, self.logo_scale):
                spin.valueChanged.connect(self.refresh)
            self.refresh()

        def current(self) -> WatermarkSettings:
            anchor = next((n for n, b in self.anchor_buttons.items() if b.isChecked()), "우하")
            return WatermarkSettings(
                enabled=self.window.watermark.enabled,
                kind="text" if self.kind_combo.currentIndex() == 0 else "image",
                text=self.text_edit.text(),
                font_family=self.font_combo.currentFont().family(),
                size_percent=self.size_spin.value(),
                opacity=self.opacity_spin.value(),
                color=self._color,
                anchor=anchor,
                margin_percent=self.margin_spin.value(),
                image_path=self.window.watermark.image_path,
                image_scale_percent=self.logo_scale.value(),
            )

        def choose_color(self):
            r, g, b = self._color
            color = QColorDialog.getColor(QColor(int(r), int(g), int(b)), self)
            if color.isValid():
                self._color = (color.red(), color.green(), color.blue())
                self.refresh()

        def choose_logo(self):
            path, _ = QFileDialog.getOpenFileName(
                self, "로고 그림 파일", "", "그림 파일 (*.png *.jpg *.jpeg *.tif *.tiff)")
            if path:
                self.window.watermark.image_path = path
                self.logo_button.setText(Path(path).name)
                self.refresh()

        def refresh(self):
            settings = self.current()
            self.window.watermark = settings
            base = self.window.preview_base()
            if base is None:
                return
            composed = apply_watermark(base, settings) if settings.usable() else base
            h, w = composed.shape[:2]
            qimg = QImage(composed.tobytes(), w, h, w * 3, QImage.Format_RGB888)
            self.preview_label.setPixmap(QPixmap.fromImage(qimg).scaled(
                self.preview_label.size(), Qt.KeepAspectRatio, Qt.SmoothTransformation))

    # ---- 흔들림 기준 대화상자 ----

    class ThresholdDialog(QDialog):
        def __init__(self, window: "MainWindow"):
            super().__init__(window)
            self.window = window
            self.setWindowTitle("흔들림 판정 기준")
            layout = QVBoxLayout(self)
            layout.addWidget(QLabel("흔들린 사진을 얼마나 엄격하게 걸러낼지 정해요."))
            self.slider = QSlider(Qt.Horizontal)
            self.slider.setRange(10, 150)
            self.slider.setValue(int(window.threshold))
            self.slider.valueChanged.connect(self.on_change)
            layout.addWidget(self.slider)
            row = QHBoxLayout()
            row.addWidget(QLabel("너그럽게 (적게 걸러냄)"))
            row.addStretch()
            self.value_label = QLabel(str(int(window.threshold)))
            row.addWidget(self.value_label)
            row.addStretch()
            row.addWidget(QLabel("엄격하게 (많이 걸러냄)"))
            layout.addLayout(row)
            done = QPushButton("완료")
            done.clicked.connect(self.accept)
            layout.addWidget(done)

        def on_change(self, value: int):
            self.value_label.setText(str(value))
            self.window.threshold = float(value)
            self.window.refresh_step2()

    # ---- 메인 창 ----

    class MainWindow(QWidget):
        def __init__(self):
            super().__init__()
            self.setWindowTitle("PhotoAgent — 사진 자동 정리·보정")
            self.resize(1180, 760)

            self.folder: Path | None = None
            self.output: Path | None = None
            self.paths: list[Path] = []
            self.metrics: list[Metrics | None] = []
            self.include_override: dict[int, bool] = {}
            self.wm_override: dict[int, bool] = {}
            self.threshold = DEFAULT_THRESHOLD
            self.watermark = WatermarkSettings()
            self._preview_cache: np.ndarray | None = None
            self._icon_cache: dict[Path, QIcon] = {}
            self.bridge = Bridge()
            self.bridge.progress.connect(self.on_progress)
            self.bridge.finished.connect(self.on_finished)

            root = QVBoxLayout(self)
            root.setContentsMargins(0, 0, 0, 0)

            # 단계 표시 헤더
            header = QHBoxLayout()
            header.addStretch()
            self.step_labels = []
            for text in ("①  사진 폴더 고르기", "②  확인하기", "③  저장하기"):
                label = QLabel(text)
                header.addWidget(label)
                self.step_labels.append(label)
            header.addStretch()
            root.addLayout(header)

            self.stack = QStackedWidget()
            root.addWidget(self.stack, 1)
            self.stack.addWidget(self.build_step1())
            self.stack.addWidget(self.build_step2())
            self.stack.addWidget(self.build_step3())
            self.goto_step(0)

        # ---------- 1단계 ----------

        def build_step1(self) -> QWidget:
            page = QWidget()
            layout = QVBoxLayout(page)
            layout.addStretch()
            title = QLabel("사진을 자동으로 정리하고 보정해 드려요")
            title.setObjectName("title")
            title.setAlignment(Qt.AlignCenter)
            layout.addWidget(title)
            subtitle = QLabel(
                "사진이 들어 있는 폴더를 고르면,\n"
                "흔들려서 흐리게 나온 사진을 자동으로 찾아내고\n"
                "잘 나온 사진만 예쁘게 보정해서 새 폴더에 저장해 드립니다.\n\n"
                "원본 사진은 절대 바뀌지 않으니 안심하세요."
            )
            subtitle.setObjectName("subtitle")
            subtitle.setAlignment(Qt.AlignCenter)
            layout.addWidget(subtitle)
            layout.addSpacing(24)
            self.pick_button = QPushButton("📁  사진 폴더 고르기")
            self.pick_button.setObjectName("primary")
            self.pick_button.clicked.connect(self.choose_folder)
            layout.addWidget(self.pick_button, alignment=Qt.AlignCenter)
            layout.addSpacing(16)
            self.step1_progress = QProgressBar()
            self.step1_progress.setFixedWidth(420)
            self.step1_progress.hide()
            layout.addWidget(self.step1_progress, alignment=Qt.AlignCenter)
            self.step1_status = QLabel("")
            self.step1_status.setObjectName("hint")
            self.step1_status.setAlignment(Qt.AlignCenter)
            layout.addWidget(self.step1_status)
            layout.addStretch()
            return page

        # ---------- 2단계 ----------

        def build_step2(self) -> QWidget:
            page = QWidget()
            layout = QVBoxLayout(page)
            layout.setContentsMargins(20, 8, 20, 12)

            self.summary_label = QLabel("")
            self.summary_label.setObjectName("summary")
            layout.addWidget(self.summary_label)
            hint = QLabel("사진을 한 번 클릭하면 저장할지(초록)·뺄지(빨강) 바꿀 수 있어요. "
                          "잘못 걸러진 사진이 있으면 클릭으로 되돌리세요.")
            hint.setObjectName("hint")
            layout.addWidget(hint)

            filter_row = QHBoxLayout()
            self.filter_buttons = []
            for text in ("전체 보기", "저장할 사진", "저장 안 할 사진"):
                button = QPushButton(text)
                button.setObjectName("secondary")
                button.setCheckable(True)
                button.clicked.connect(self.on_filter)
                filter_row.addWidget(button)
                self.filter_buttons.append(button)
            self.filter_buttons[0].setChecked(True)
            filter_row.addStretch()
            adjust = QPushButton("흔들림 판정 기준 조절")
            adjust.setObjectName("secondary")
            adjust.clicked.connect(lambda: ThresholdDialog(self).exec())
            filter_row.addWidget(adjust)
            layout.addLayout(filter_row)

            self.list_widget = QListWidget()
            self.list_widget.setViewMode(QListWidget.IconMode)
            self.list_widget.setIconSize(QSize(176, 132))
            self.list_widget.setResizeMode(QListWidget.Adjust)
            self.list_widget.setSpacing(10)
            self.list_widget.setWordWrap(True)
            self.list_widget.itemClicked.connect(self.on_item_clicked)
            self.list_widget.setContextMenuPolicy(Qt.CustomContextMenu)
            self.list_widget.customContextMenuRequested.connect(self.context_menu)
            layout.addWidget(self.list_widget, 1)

            wm_row = QHBoxLayout()
            self.wm_check = QCheckBox("저장할 때 사진에 이름/로고 넣기 (워터마크)")
            self.wm_check.toggled.connect(self.on_wm_toggle)
            wm_row.addWidget(self.wm_check)
            wm_design = QPushButton("이름/로고 꾸미기…")
            wm_design.setObjectName("secondary")
            wm_design.clicked.connect(self.open_watermark)
            wm_row.addWidget(wm_design)
            wm_row.addStretch()
            wm_row.addWidget(QLabel("저장 크기"))
            self.size_combo = QComboBox()
            for label, _ in EXPORT_SIZES:
                self.size_combo.addItem(label)
            self.size_combo.setToolTip("저장할 사진의 크기예요. 작게 하면 파일 용량이 줄어요.")
            wm_row.addWidget(self.size_combo)
            wm_row.addWidget(QLabel("파일 형식"))
            self.fmt_combo = QComboBox()
            self.fmt_combo.addItems(["JPG (추천)", "PNG", "WebP"])
            self.fmt_combo.setToolTip("잘 모르겠으면 JPG 를 그대로 두세요.")
            wm_row.addWidget(self.fmt_combo)
            layout.addLayout(wm_row)

            bottom = QHBoxLayout()
            back = QPushButton("← 다른 폴더 고르기")
            back.setObjectName("secondary")
            back.clicked.connect(lambda: self.goto_step(0))
            bottom.addWidget(back)
            bottom.addStretch()
            self.export_button = QPushButton("✨  보정해서 저장하기")
            self.export_button.setObjectName("primary")
            self.export_button.clicked.connect(self.start_export)
            bottom.addWidget(self.export_button)
            layout.addLayout(bottom)
            return page

        # ---------- 3단계 ----------

        def build_step3(self) -> QWidget:
            page = QWidget()
            layout = QVBoxLayout(page)
            layout.addStretch()
            self.step3_title = QLabel("사진을 보정하고 있어요…")
            self.step3_title.setObjectName("title")
            self.step3_title.setAlignment(Qt.AlignCenter)
            layout.addWidget(self.step3_title)
            self.step3_status = QLabel("잠시만 기다려 주세요. 사진이 많으면 몇 분 걸릴 수 있어요.")
            self.step3_status.setObjectName("subtitle")
            self.step3_status.setAlignment(Qt.AlignCenter)
            layout.addWidget(self.step3_status)
            layout.addSpacing(16)
            self.step3_progress = QProgressBar()
            self.step3_progress.setFixedWidth(460)
            layout.addWidget(self.step3_progress, alignment=Qt.AlignCenter)
            layout.addSpacing(24)
            buttons = QHBoxLayout()
            buttons.addStretch()
            self.open_folder_button = QPushButton("📂  저장된 폴더 열기")
            self.open_folder_button.setObjectName("primary")
            self.open_folder_button.clicked.connect(
                lambda: self.output and open_in_explorer(self.output))
            self.open_folder_button.hide()
            buttons.addWidget(self.open_folder_button)
            self.restart_button = QPushButton("처음부터 다시")
            self.restart_button.setObjectName("secondary")
            self.restart_button.clicked.connect(lambda: self.goto_step(0))
            self.restart_button.hide()
            buttons.addWidget(self.restart_button)
            buttons.addStretch()
            layout.addLayout(buttons)
            layout.addStretch()
            return page

        # ---------- 단계 전환 ----------

        def goto_step(self, index: int):
            self.stack.setCurrentIndex(index)
            for i, label in enumerate(self.step_labels):
                label.setObjectName("stepOn" if i == index else "stepOff")
                label.style().unpolish(label)
                label.style().polish(label)

        # ---------- 상태 ----------

        def verdict(self, index: int) -> str:
            return verdict_for(self.metrics[index], self.threshold)

        def included(self, index: int) -> bool:
            if index in self.include_override:
                return self.include_override[index]
            return auto_included(self.verdict(index))

        def wm_applies(self, index: int) -> bool:
            if not self.watermark.usable():
                return False
            return self.wm_override.get(index, self.watermark.enabled)

        def preview_base(self) -> np.ndarray | None:
            if self._preview_cache is not None:
                return self._preview_cache
            for path in self.paths[:1]:
                rgb = load_rgb(path)
                if rgb is not None:
                    scale = 1200 / max(rgb.shape[:2])
                    if scale < 1:
                        rgb = cv2.resize(rgb, None, fx=scale, fy=scale,
                                         interpolation=cv2.INTER_AREA)
                    self._preview_cache = np.ascontiguousarray(rgb)
                    return self._preview_cache
            self._preview_cache = np.full((600, 900, 3), 96, np.uint8)
            return self._preview_cache

        # ---------- 1단계 동작 ----------

        def choose_folder(self):
            path = QFileDialog.getExistingDirectory(self, "사진이 들어 있는 폴더를 고르세요")
            if path:
                self.set_folder(Path(path))
                self.start_analysis()

        def set_folder(self, folder: Path):
            self.folder = folder
            self.paths = scan_images(folder)
            self.metrics = [None] * len(self.paths)
            self.include_override.clear()
            self.wm_override.clear()
            self._preview_cache = None
            self._icon_cache.clear()

        def start_analysis(self):
            if not self.paths:
                self.step1_status.setText("이 폴더에는 사진이 없어요. 다른 폴더를 골라 주세요.")
                return
            self.pick_button.setEnabled(False)
            self.step1_progress.setRange(0, len(self.paths))
            self.step1_progress.setValue(0)
            self.step1_progress.show()
            self.step1_status.setText("사진을 살펴보고 있어요…")

            def work():
                with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
                    futures = {pool.submit(analyze, p): i for i, p in enumerate(self.paths)}
                    done = 0
                    for future in as_completed(futures):
                        self.metrics[futures[future]] = future.result()
                        done += 1
                        self.bridge.progress.emit(
                            done, len(self.paths),
                            f"사진을 살펴보고 있어요… {done} / {len(self.paths)}")
                self.bridge.finished.emit("analysis")

            import threading
            threading.Thread(target=work, daemon=True).start()

        # ---------- 2단계 동작 ----------

        def refresh_step2(self):
            total = len(self.paths)
            saved = sum(1 for i in range(total) if self.included(i))
            blurry = sum(1 for i in range(total) if self.verdict(i) == VERDICT_BLURRY)
            exposure = sum(1 for i in range(total)
                           if self.verdict(i) in (VERDICT_DARK, VERDICT_BRIGHT))
            parts = [f"모두 {total}장 중 저장할 사진 {saved}장"]
            if blurry:
                parts.append(f"흔들려 흐린 사진 {blurry}장")
            if exposure:
                parts.append(f"너무 어둡거나 밝은 사진 {exposure}장")
            self.summary_label.setText(" · ".join(parts))
            self.filter_buttons[1].setText(f"저장할 사진 {saved}")
            self.filter_buttons[2].setText(f"저장 안 할 사진 {total - saved}")
            self.refresh_grid()

        def on_filter(self):
            sender = self.sender()
            for button in self.filter_buttons:
                button.setChecked(button is sender)
            self.refresh_grid()

        def current_filter(self) -> int:
            return next((i for i, b in enumerate(self.filter_buttons) if b.isChecked()), 0)

        def refresh_grid(self):
            mode = self.current_filter()
            self.list_widget.clear()
            for i, path in enumerate(self.paths):
                included = self.included(i)
                if mode == 1 and not included:
                    continue
                if mode == 2 and included:
                    continue
                verdict = self.verdict(i)
                easy, color = EASY_VERDICT.get(verdict, (verdict, "#555"))
                if verdict == VERDICT_GOOD and self.metrics[i] \
                        and is_bokeh(self.metrics[i], self.threshold):
                    easy = "잘 나온 사진 (배경 흐림 효과)"
                state = "✔ 저장함" if included else "✖ 저장 안 함"
                if self.wm_applies(i):
                    state += " · 워터마크"
                item = QListWidgetItem(f"{path.name}\n{easy}\n{state}")
                item.setData(Qt.UserRole, i)
                item.setIcon(self.thumbnail_icon(path))
                item.setForeground(QColor("#2e7d32") if included else QColor("#c62828"))
                item.setToolTip("클릭하면 저장할지 여부가 바뀝니다")
                self.list_widget.addItem(item)

        def thumbnail_icon(self, path: Path) -> QIcon:
            if path in self._icon_cache:
                return self._icon_cache[path]
            reader = QImageReader(str(path))
            reader.setAutoTransform(True)
            size = reader.size()
            if size.width() > 0:
                scale = 352 / max(size.width(), size.height())
                if scale < 1:
                    reader.setScaledSize(QSize(int(size.width() * scale),
                                               int(size.height() * scale)))
            image = reader.read()
            icon = QIcon(QPixmap.fromImage(image)) if not image.isNull() else QIcon()
            self._icon_cache[path] = icon
            return icon

        def on_item_clicked(self, item: QListWidgetItem):
            index = item.data(Qt.UserRole)
            self.include_override[index] = not self.included(index)
            if self.include_override[index] == auto_included(self.verdict(index)):
                del self.include_override[index]
            self.refresh_step2()

        def context_menu(self, pos):
            item = self.list_widget.itemAt(pos)
            if item is None:
                return
            index = item.data(Qt.UserRole)
            menu = QMenu(self)
            wm_action = menu.addAction(
                "이 사진 워터마크 빼기" if self.wm_applies(index) else "이 사진에만 워터마크 넣기")
            wm_action.setEnabled(self.watermark.usable())
            reset = menu.addAction("자동 판정으로 되돌리기")
            chosen = menu.exec(self.list_widget.mapToGlobal(pos))
            if chosen == wm_action:
                current = self.wm_applies(index)
                self.wm_override[index] = not current
                if self.wm_override[index] == self.watermark.enabled:
                    del self.wm_override[index]
            elif chosen == reset:
                self.include_override.pop(index, None)
            self.refresh_step2()

        def on_wm_toggle(self, checked: bool):
            self.watermark.enabled = checked
            if checked and not self.watermark.usable():
                self.open_watermark()
            self.refresh_grid()

        def open_watermark(self):
            self._preview_cache = None
            WatermarkDialog(self).exec()
            if self.watermark.usable() and self.wm_check.isChecked():
                self.watermark.enabled = True
            self.refresh_grid()

        # ---------- 3단계 동작 ----------

        def export_options(self) -> tuple[int, str]:
            max_edge = EXPORT_SIZES[self.size_combo.currentIndex()][1]
            fmt = ["JPG", "PNG", "WebP"][self.fmt_combo.currentIndex()]
            return max_edge, fmt

        def build_jobs(self) -> list[Job]:
            assert self.folder is not None
            self.output = self.folder.parent / f"{self.folder.name}_결과"
            _, fmt = self.export_options()
            ext = EXPORT_FORMATS[fmt][1]
            jobs: list[Job] = []
            for i, path in enumerate(self.paths):
                verdict = self.verdict(i)
                if self.included(i):
                    wm = self.watermark if self.wm_applies(i) else None
                    jobs.append(Job("enhance", path,
                                    self.output / "보정완료" / f"{path.stem}{ext}", wm))
                else:
                    jobs.append(Job("copy", path,
                                    self.output / "제외됨" / REJECT_FOLDER[verdict] / path.name))
            return jobs

        def write_report(self, failures: list[str]):
            if self.output is None:
                return
            try:
                lines = [f"PhotoAgent(Windows) 처리 결과 — 임계값 {self.threshold:.0f}"]
                for i, path in enumerate(self.paths):
                    tag = "보정" if self.included(i) else f"제외·{self.verdict(i)}"
                    if self.included(i) and self.wm_applies(i):
                        tag += "+워터마크"
                    lines.append(f"[{tag}] {path.name}")
                if failures:
                    lines.append("")
                    lines.extend(f"실패: {f}" for f in failures)
                (self.output / "처리결과.txt").write_text("\n".join(lines), encoding="utf-8")
            except OSError:
                pass

        def start_export(self):
            jobs = self.build_jobs()
            if not jobs:
                return
            self.goto_step(2)
            self.step3_title.setText("사진을 보정하고 있어요…")
            self.step3_status.setText("잠시만 기다려 주세요. 사진이 많으면 몇 분 걸릴 수 있어요.")
            self.open_folder_button.hide()
            self.restart_button.hide()
            self.step3_progress.show()
            self.step3_progress.setRange(0, len(jobs))
            self.step3_progress.setValue(0)

            max_edge, fmt = self.export_options()

            def work():
                failures = run_jobs(
                    jobs,
                    progress_cb=lambda done, total: self.bridge.progress.emit(
                        done, total, f"사진을 보정하고 있어요… {done} / {total}"),
                    max_edge=max_edge,
                    fmt=fmt,
                )
                self.write_report(failures)
                saved = sum(1 for j in jobs if j.mode == "enhance")
                message = f"🎉 완료! 보정한 사진 {saved}장을 저장했어요."
                if failures:
                    message += f" ({len(failures)}장은 저장하지 못했어요)"
                self.bridge.finished.emit(message)

            import threading
            threading.Thread(target=work, daemon=True).start()

        # ---------- 신호 ----------

        def on_progress(self, done: int, total: int, message: str):
            if self.stack.currentIndex() == 0:
                self.step1_progress.setValue(done)
                self.step1_status.setText(message)
            else:
                self.step3_progress.setValue(done)
                self.step3_status.setText(message)

        def on_finished(self, message: str):
            if message == "analysis":
                self.pick_button.setEnabled(True)
                self.step1_progress.hide()
                self.step1_status.setText("")
                self.refresh_step2()
                self.goto_step(1)
            else:
                self.step3_progress.hide()
                self.step3_title.setText(message)
                self.step3_status.setText(f"저장 위치: {self.output}")
                self.open_folder_button.show()
                self.restart_button.show()

    app = QApplication(sys.argv if not (smoke or smoke_folder) else [sys.argv[0]])
    app.setStyleSheet(STYLESHEET)
    window = MainWindow()

    if smoke_folder:
        # 헤드리스 전체 흐름 검증: 폴더 → 분석 → 2단계 → 내보내기
        shots_dir = os.environ.get("PHOTOAGENT_SHOTS")
        window.show()
        if shots_dir:
            window.grab().save(str(Path(shots_dir) / "step1.png"))
        window.set_folder(Path(smoke_folder))
        for i, path in enumerate(window.paths):
            window.metrics[i] = analyze(path)
        window.refresh_step2()
        window.goto_step(1)
        if shots_dir:
            app.processEvents()
            window.grab().save(str(Path(shots_dir) / "step2.png"))
        window.watermark = WatermarkSettings(enabled=True, text="© SMOKE")
        window.wm_check.setChecked(True)
        jobs = window.build_jobs()
        failures = run_jobs(jobs)
        window.write_report(failures)
        ok = (not failures and window.output is not None
              and any((window.output / "보정완료").glob("*.jpg")))
        print("GUI FULL SMOKE OK" if ok else f"GUI FULL SMOKE FAILED: {failures}")
        window.close()
        return 0 if ok else 1

    if smoke:
        window.show()
        window.close()
        print("GUI SMOKE OK")
        return 0

    window.show()
    return app.exec()


# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="PhotoAgent for Windows")
    parser.add_argument("--cli", metavar="폴더", help="GUI 없이 분석·내보내기")
    parser.add_argument("--out", metavar="폴더", help="출력 폴더")
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-sharpen", action="store_true")
    parser.add_argument("--watermark-text", metavar="문구", help="CLI 텍스트 워터마크")
    parser.add_argument("--max-edge", type=int, default=0, help="긴 변 픽셀 제한 (0=원본)")
    parser.add_argument("--format", choices=["jpg", "png", "webp"], default="jpg")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--smoke", action="store_true", help="GUI 생성 후 즉시 종료 (테스트)")
    parser.add_argument("--smoke-full", metavar="폴더", help="GUI 전체 흐름 헤드리스 검증")
    args = parser.parse_args()

    if args.selftest:
        return run_selftest()
    if args.cli:
        return run_cli(args)
    if args.smoke_full:
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        return run_gui(smoke_folder=args.smoke_full)
    return run_gui(smoke=args.smoke)


if __name__ == "__main__":
    sys.exit(main())
