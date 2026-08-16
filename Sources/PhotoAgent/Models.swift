import Foundation

/// 한 장의 사진에서 측정한 품질 지표
struct PhotoMetrics: Sendable {
    /// 전역 Laplacian variance — 값이 클수록 선명
    var sharpness: Double
    /// 상위 타일 선명도 (상위 2개 평균) — 아웃포커싱 사진도 피사체 타일은 높다
    var tileTopSharpness: Double
    /// 타일 선명도 중앙값 — 배경 흐림 정도
    var tileMedianSharpness: Double
    /// Vision 주목 영역(피사체) 선명도. 검출 실패 시 nil
    var saliencySharpness: Double?
    /// 블러 방향성. 1≈등방(초점 블러), 클수록 방향성(흔들림)
    var anisotropy: Double
    /// 평균 휘도 (0–255)
    var meanLuma: Double
    /// 하이라이트 클리핑 비율 (0–1)
    var clippedHighlightRatio: Double
    /// 섀도우 클리핑 비율 (0–1)
    var clippedShadowRatio: Double
    var pixelWidth: Int
    var pixelHeight: Int

    /// 판정에 쓰는 피사체 선명도 — saliency 영역과 상위 타일 중 큰 값
    var subjectSharpness: Double {
        max(tileTopSharpness, saliencySharpness ?? 0)
    }
}

/// 사이드바 필터
enum FilterTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all = "전체"
    case included = "보정 대상"
    case excluded = "제외 대상"
    case bokeh = "아웃포커싱"
    case blurry = "흔들림"
    case defocus = "초점불량"
    case exposure = "노출불량"
    case edited = "편집한 사진"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .all: return "photo.on.rectangle"
        case .included: return "checkmark.circle"
        case .excluded: return "xmark.bin"
        case .bokeh: return "camera.aperture"
        case .blurry: return "wind"
        case .defocus: return "circle.dashed"
        case .exposure: return "sun.max"
        case .edited: return "slider.horizontal.3"
        }
    }
}

enum Verdict: String, Sendable, CaseIterable {
    case good = "양호"
    case blurry = "흔들림"
    case defocus = "초점불량"
    case dark = "너무 어두움"
    case bright = "과노출"
    case failed = "분석 실패"

    /// 제외 사진을 정리할 하위 폴더 이름
    var rejectFolderName: String {
        switch self {
        case .good: return "수동제외"
        case .blurry: return "흔들림"
        case .defocus: return "초점불량"
        case .dark: return "어두움"
        case .bright: return "과노출"
        case .failed: return "분석실패"
        }
    }
}

/// 사진별 심도(배경 흐림) 설정.
/// sigma 값은 DepthEffect.referenceDimension(1400px) 기준 — 저장 시 원본 크기에 비례 스케일.
struct DepthSettings: Sendable, Equatable {
    var blurRadius: Double = 12
    var feather: Double = 4
}

/// 피사체 또는 배경 한 영역에만 적용하는 보정 값. 0 = 변경 없음.
struct RegionAdjustments: Sendable, Equatable {
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    var sharpness: Double = 0
    var noiseReduction: Double = 0

    var isNeutral: Bool { self == RegionAdjustments() }

    /// 전역 파이프라인(applyAdjustments)을 재사용하기 위한 변환
    var asEditSettings: EditSettings {
        EditSettings(
            autoEnhance: false,
            exposure: exposure,
            contrast: contrast,
            highlights: highlights,
            shadows: shadows,
            temperature: temperature,
            tint: tint,
            vibrance: vibrance,
            saturation: saturation,
            sharpness: sharpness,
            noiseReduction: noiseReduction
        )
    }
}

/// 사진별 수동 보정 설정. 0 = 변경 없음(중립).
struct EditSettings: Sendable, Equatable {
    var autoEnhance: Bool = true
    var exposure: Double = 0        // EV, -2…+2
    var contrast: Double = 0        // -100…100
    var highlights: Double = 0      // -100…100
    var shadows: Double = 0         // -100…100
    var temperature: Double = 0     // -100(차갑게)…+100(따뜻하게)
    var tint: Double = 0            // -100(초록)…+100(마젠타)
    var vibrance: Double = 0        // -100…100
    var saturation: Double = 0      // -100…100
    var sharpness: Double = 0       // 0…100
    var noiseReduction: Double = 0  // 0…100
    var vignette: Double = 0        // 0…100
    var straighten: Double = 0      // 도(°), -10…+10
    /// 피사체 영역 전용 보정 (Vision 마스크 기반)
    var subject: RegionAdjustments = RegionAdjustments()
    /// 배경 영역 전용 보정
    var background: RegionAdjustments = RegionAdjustments()
    /// 영역 경계 페더 sigma (1400px 기준)
    var regionFeather: Double = 3

    var hasRegionEdits: Bool { !subject.isNeutral || !background.isNeutral }
}

/// 내보내기 파일 형식
enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG"
    case heic = "HEIC"
    case png = "PNG"

    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .png: return "png"
        }
    }
}

/// 내보내기 크기 (긴 변 픽셀, 0 = 원본 유지)
enum ExportSize: Int, CaseIterable, Identifiable, Sendable {
    case original = 0
    case large = 4096
    case medium = 2048
    case small = 1280

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .original: return "원본 크기"
        case .large: return "크게 (4096px)"
        case .medium: return "보통 (2048px)"
        case .small: return "작게 (1280px)"
        }
    }
}

/// 워터마크 위치 앵커 (3×3)
enum WatermarkAnchor: String, CaseIterable, Identifiable, Sendable {
    case topLeft = "좌상", top = "상단", topRight = "우상"
    case left = "좌측", center = "중앙", right = "우측"
    case bottomLeft = "좌하", bottom = "하단", bottomRight = "우하"
    var id: String { rawValue }
}

enum WatermarkKind: String, CaseIterable, Identifiable, Sendable {
    case text = "텍스트"
    case image = "이미지 로고"
    var id: String { rawValue }
}

/// 전역 워터마크 설정. 크기·여백은 이미지 긴 변 대비 % — 해상도 무관하게 동일 비율.
struct WatermarkSettings: Sendable, Equatable {
    var enabled = false               // 전역 기본 적용 여부 (사진별 override 가능)
    var kind: WatermarkKind = .text
    var text = "© PhotoAgent"
    var fontName = "AppleSDGothicNeo-Bold"
    var sizePercent: Double = 4       // 텍스트 크기 (긴 변 %)
    var opacity: Double = 0.7
    var colorRed: Double = 1
    var colorGreen: Double = 1
    var colorBlue: Double = 1
    var anchor: WatermarkAnchor = .bottomRight
    var marginPercent: Double = 3
    var imagePath: String = ""        // 로고 파일 경로
    var imageScalePercent: Double = 15 // 로고 폭 (긴 변 %)

    /// 적용 가능한 상태인지 (내용이 채워졌는지)
    var isUsable: Bool {
        switch kind {
        case .text: return !text.trimmingCharacters(in: .whitespaces).isEmpty
        case .image: return !imagePath.isEmpty && FileManager.default.fileExists(atPath: imagePath)
        }
    }
}

struct EditPreset: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let settings: EditSettings

    static let all: [EditPreset] = [
        EditPreset(name: "기본 (자동 보정만)", settings: EditSettings()),
        EditPreset(name: "선명하게", settings: EditSettings(contrast: 12, vibrance: 15, sharpness: 40)),
        EditPreset(name: "인물", settings: EditSettings(highlights: -20, shadows: 15, temperature: 10, vibrance: 10, sharpness: 20)),
        EditPreset(name: "풍경", settings: EditSettings(contrast: 15, vibrance: 30, saturation: 5, sharpness: 30)),
        EditPreset(name: "음식", settings: EditSettings(shadows: 10, temperature: 15, vibrance: 25, sharpness: 25)),
        EditPreset(name: "흑백", settings: EditSettings(contrast: 20, saturation: -100)),
        EditPreset(name: "피사체 강조 (영역)", settings: {
            var settings = EditSettings()
            settings.subject.exposure = 0.3
            settings.subject.sharpness = 25
            settings.subject.vibrance = 10
            settings.background.exposure = -0.4
            settings.background.saturation = -25
            return settings
        }()),
        EditPreset(name: "배경 정리 (영역)", settings: {
            var settings = EditSettings()
            settings.background.saturation = -40
            settings.background.contrast = -10
            settings.background.noiseReduction = 30
            return settings
        }()),
    ]
}

struct PhotoItem: Identifiable, Sendable {
    let id: UUID
    let url: URL
    var metrics: PhotoMetrics?
    var analysisDone = false
    /// nil = 자동 판정 따름, true = 강제 포함, false = 강제 제외
    var userDecision: Bool?
    /// 심도 편집 설정 — nil 이면 효과 없음
    var depth: DepthSettings?
    /// 수동 보정 설정 — nil 이면 기본(자동 보정 + 전역 선명화 옵션)
    var edits: EditSettings?
    /// 워터마크 사진별 override — nil 이면 전역 기본(enabled) 따름
    var watermarkOverride: Bool?
}
