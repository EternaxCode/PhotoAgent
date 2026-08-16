# PhotoAgent

Automatic photo culling and enhancement for macOS (native Swift + SwiftUI + Core Image) and Windows (Python + Qt).

PhotoAgent scans a folder of photos, detects camera shake — and knows the difference
between shake and intentional bokeh — then enhances your best shots and exports them
to a separate folder. **Originals are never modified.**

**Website:** https://eternaxcode.github.io/PhotoAgent/

## Download

Grab the latest installers from the [**Releases page**](https://github.com/EternaxCode/PhotoAgent/releases):

| File | Platform | Install |
|---|---|---|
| `PhotoAgent-mac.dmg` | macOS 14+ | Open the DMG and drag PhotoAgent to Applications. First launch: **right-click → Open** (unidentified-developer prompt) |
| `PhotoAgent-Setup.exe` | Windows 10/11 | Run the installer — no Python required. If SmartScreen appears: "More info → Run anyway" |
| `PhotoAgent-Windows.zip` | Windows (manual) | For developers — requires Python, run `install.bat` |

> The macOS app is ad-hoc signed (not notarized), so macOS shows an
> "unidentified developer" warning on first launch. Right-click the app and
> choose **Open** once; macOS remembers your choice afterwards.

## UI overview (macOS, three panes)

- **Left sidebar** — source/output folder management · filters (all / keepers /
  excluded / bokeh / shake / soft focus / exposure / edited, with counts) ·
  shake-threshold slider
- **Center grid** — thumbnails with verdict badges; thumbnail-size slider in the
  status bar
- **Right inspector** — verdict metrics, EXIF (camera, aperture, shutter, ISO,
  capture date), and quick actions (editor, keep/exclude, reveal in Finder)

## Workflow

1. Pick the **source folder** in the sidebar
2. **Analyze** (⌘R) — sharpness and exposure are measured per photo
3. Review the grid: **click = select** (inspector), **double-click = editor**,
   **✓/✕ icon = toggle keep/exclude**
   - Use sidebar filters to review only shaky or excluded photos
   - Moving the threshold slider re-classifies instantly (no re-analysis)
4. **Export** (⌘E) — the output folder opens in Finder when done

## Menu bar shortcuts

| Menu | Items |
|---|---|
| File | Open source folder ⌘O · Choose output folder ⇧⌘O · Reveal output in Finder |
| Photos | Analyze ⌘R · Export ⌘E · Open editor ↩ · Toggle keep/exclude ⌘K |
| Adjustments | Copy settings ⇧⌘C · Paste ⇧⌘V · Apply to all keepers ⌥⇧⌘V · Clear settings |
| View | Filters ⌘1–⌘5 · Inspector ⌥⌘I |

## Output structure

```
<source-folder>_결과/
├── 보정완료/        enhanced photos (EXIF preserved, quality 92)
├── 제외됨/          excluded originals, filed by reason
│   ├── 흔들림/      camera shake
│   ├── 어두움/      too dark
│   ├── 과노출/      overexposed
│   └── 수동제외/    manually excluded
└── 처리결과.txt     per-photo verdict report
```

## How verdicts work

PhotoAgent distinguishes intentional background blur (bokeh) from camera shake:

1. **Subject sharpness** — the larger of the Vision saliency-region score and the
   top tile-level Laplacian variance. A bokeh shot survives here because its
   subject tiles stay sharp even when the background is soft.
2. **Blur directionality (anisotropy)** — the eigenvalue ratio of the gradient
   structure tensor. Motion blur smears in one direction (ratio ≥ 2.5), while
   defocus blur is isotropic (ratio ≈ 1).

| Verdict | Condition | Action |
|---|---|---|
| Good | subject sharpness ≥ threshold × 2 | enhance |
| Good · bokeh | good + low background-tile median | enhance (badge) |
| Camera shake | everything soft + anisotropy ≥ 2.5 | **exclude** |
| Soft focus | everything soft + isotropic | enhance (may be intentional; badge) |
| Too dark | mean luma < 32 and shadow clipping > 35% | exclude |
| Overexposed | mean luma > 218 or highlight clipping > 45% | exclude |

Only shaken photos (and exposure failures) are auto-excluded — bokeh and
soft-focus shots stay in the keep pile, and any verdict can be overridden with a
click. A "soft subject?" badge warns when the background is sharp but the
subject region is not (likely missed focus).

Base enhancement: Core Image auto adjustments (tone curve, vibrance,
highlight/shadow, face balance, red-eye removal) plus optional sharpening.

## Per-photo editor (macOS)

Open it from a grid cell's slider icon or right-click → Open editor. Every
adjustment updates a live preview with an RGB histogram.

| Section | Adjustments |
|---|---|
| Basic | Exposure (EV), contrast, highlights, shadows |
| Color | Temperature, tint, vibrance, saturation |
| Detail | Sharpening, noise reduction |
| Effects | Vignette, straighten (±10°), background blur (depth) + edge feather |

### Region-separated editing (subject / background)

Switch scope with the **[All | Subject | Background]** tabs. Using the Vision
subject mask, apply **different adjustments to subject and background**:

- Independent exposure, contrast, highlights, shadows, temperature, tint,
  vibrance, saturation, sharpening, and noise reduction per region
- **Edge feather** slider blends the seam between regions
- Composited as global → region → depth → straighten; the mask is generated once
  and shared
- Example: subject +0.3 EV + sharpening, background −0.4 EV + desaturation →
  the subject pops

More editor features:

- **Auto-enhance** toggle (Apple auto adjustments on/off)
- **Presets**: Default / Crisp / Portrait / Landscape / Food / B&W /
  **Subject pop (region)** / **Background cleanup (region)**
- **⌘← / ⌘→** — auto-apply and move to the previous/next photo
- **Compare original** toggle, **show subject mask**, double-click a label to
  reset that value
- Depth blur uses the Vision subject-lifting mask (background only); disabled
  when no subject is detected
- Edited cells get `편집`/`심도` badges; exports apply the same proportions at
  full resolution

### Copy / batch-apply settings

Right-click a cell → **Copy settings**, then **Paste** onto another cell, or
**Apply copied settings to all keepers** for one-pass batch grading.

## Watermark

Toolbar **Watermark** button (⇧⌘W) opens the settings sheet with a live preview:

- **Text**: custom string, any system font, size (% of long edge), color —
  a legibility shadow is added automatically
- **Image logo**: PNG (transparent background recommended), width %
- Common: opacity, margin, 3×3 position anchor
- **Batch**: "Apply to all photos" button or the Adjustments menu
- **Selective**: right-click a cell → toggle watermark, or use the inspector —
  per-photo overrides on top of the global default
- Composited at full resolution on export; watermarked cells show a `WM` badge

## Export size & format

Sidebar "Export settings" — size (original / 4096 / 2048 / 1280 px long edge)
and format (JPEG / HEIC / PNG). Resizing uses Lanczos; the watermark scales to
the output size.

## Windows version

The `windows/` folder contains the cross-platform Python + Qt version
(see `windows/README_WINDOWS.md`). Same detection algorithm and thresholds.

- **Install**: run `PhotoAgent-Setup.exe` from Releases — built automatically by
  GitHub Actions (`.github/workflows/build-windows.yml`) with PyInstaller and
  Inno Setup. Start-menu and desktop shortcuts included; no Python needed.
- **UI**: a beginner-friendly three-step wizard — ① pick a folder → ② review →
  ③ save. Plain-language verdicts, one-click keep/exclude, open-folder button
  when finished.
- Watermarking (batch/selective), export size (original/4096/2048/1280) and
  format (JPG/PNG/WebP) supported.
- Not included on Windows: the per-photo editor, depth blur, and region editing
  (they depend on Apple's Vision framework).

## CLI mode

Both versions run headless:

```sh
# macOS
.build/release/PhotoAgent --cli <folder> --dry-run          # analyze only
.build/release/PhotoAgent --cli <folder> --out <output> --threshold 60 --no-sharpen
.build/release/PhotoAgent --selftest                        # pipeline self-check

# Windows
python photoagent_win.py --cli <folder> --watermark-text "© Name" --max-edge 2048 --format webp
python photoagent_win.py --selftest
```

## Building from source

```sh
# macOS app bundle (requires Xcode command-line tools)
./build_app.sh            # → dist/PhotoAgent.app

# Windows executable (on Windows)
cd windows && build_exe.bat   # → dist/PhotoAgent.exe
```

## Supported formats

Input: jpg, jpeg, png, heic, heif, tif, tiff, bmp, webp.

## Notes

- macOS asks for permission the first time the app reads a protected folder
  (Pictures, Desktop, etc.).
- Distribution builds are unsigned (ad-hoc on macOS, no Authenticode on
  Windows); see the FAQ on the website for the one-time bypass steps.

## Support the project

If PhotoAgent saves you time, consider supporting development — any amount helps.

**[💙 Donate via Stripe](https://buy.stripe.com/7sY9AT1Fk53k62va2Mg3600)**

## License

**Apache License 2.0** — see [LICENSE](LICENSE). Copyright 2026 EternaxCode.

When copying, redistributing, or modifying this code (including copies produced
with or assisted by AI tools), Section 4 of the Apache License requires you to
**retain**:

1. The `LICENSE` and `NOTICE` files and the copyright attribution
   (Copyright 2026 EternaxCode)
2. The copyright headers in each source file
3. A statement of significant changes made to the original

Removing the attribution while copying this code is a license violation.
Additionally, use of this repository's contents as **machine-learning training
data is not permitted** (see [NOTICE](NOTICE)).
