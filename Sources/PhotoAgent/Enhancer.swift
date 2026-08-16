import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum EnhanceError: Error, LocalizedError {
    case loadFailed
    case renderFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed: return "이미지를 불러오지 못했습니다"
        case .renderFailed: return "보정 이미지 렌더링에 실패했습니다"
        case .writeFailed: return "파일 저장에 실패했습니다"
        }
    }
}

enum Enhancer {
    /// 공유 CIContext — CIContext 는 스레드 안전하다.
    static let sharedContext = CIContext(options: [.cacheIntermediates: false])

    static func loadImage(from url: URL) throws -> CIImage {
        var loaded = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        if loaded == nil,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            loaded = CIImage(cgImage: cgImage)
        }
        guard let image = loaded else { throw EnhanceError.loadFailed }
        return image
    }

    private static func filtered(_ image: CIImage, name: String, parameters: [String: Any]) -> CIImage {
        guard let filter = CIFilter(name: name) else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        for (key, value) in parameters { filter.setValue(value, forKey: key) }
        return filter.outputImage ?? image
    }

    /// Core Image 자동 보정 (톤커브, 비브런스, 하이라이트/섀도우, 얼굴 밸런스, 레드아이)
    static func applyAuto(_ input: CIImage) -> CIImage {
        var image = input
        for filter in image.autoAdjustmentFilters(options: [.crop: false, .level: false]) {
            filter.setValue(image, forKey: kCIInputImageKey)
            if let output = filter.outputImage { image = output }
        }
        return image
    }

    /// 수동 보정 파이프라인 (색·톤·디테일). autoEnhance 와 수평(기하)은 별도 처리 —
    /// 편집기의 autoAuto 캐시, 심도 마스크 정렬 때문.
    static func applyAdjustments(_ input: CIImage, settings s: EditSettings) -> CIImage {
        var image = input

        // 화이트밸런스 — targetNeutral 온도를 낮추면 따뜻해진다 (selftest 로 방향 검증)
        if abs(s.temperature) > 0.5 || abs(s.tint) > 0.5 {
            image = filtered(image, name: "CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - s.temperature * 30, y: s.tint),
            ])
        }
        // 노출
        if abs(s.exposure) > 0.01 {
            image = filtered(image, name: "CIExposureAdjust", parameters: [
                kCIInputEVKey: s.exposure,
            ])
        }
        // 섀도우 복원 + 하이라이트 감쇠
        if abs(s.shadows) > 0.5 || s.highlights < -0.5 {
            image = filtered(image, name: "CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": s.shadows / 100,
                "inputHighlightAmount": s.highlights < 0 ? max(0.3, 1 + s.highlights / 100 * 0.7) : 1.0,
            ])
        }
        // 하이라이트 강조(양수)는 톤커브 상단 리프트로
        if s.highlights > 0.5 {
            let lift = s.highlights / 100 * 0.12
            image = filtered(image, name: "CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + lift),
                "inputPoint4": CIVector(x: 1, y: 1),
            ])
        }
        // 대비/채도
        if abs(s.contrast) > 0.5 || abs(s.saturation) > 0.5 {
            image = filtered(image, name: "CIColorControls", parameters: [
                kCIInputContrastKey: 1 + s.contrast / 100 * 0.4,
                kCIInputSaturationKey: max(0, 1 + s.saturation / 100),
                kCIInputBrightnessKey: 0,
            ])
        }
        // 생동감 — 이미 채도 높은 영역은 보호
        if abs(s.vibrance) > 0.5 {
            image = filtered(image, name: "CIVibrance", parameters: [
                "inputAmount": s.vibrance / 100,
            ])
        }
        // 노이즈 감소 (선명화보다 먼저)
        if s.noiseReduction > 0.5 {
            image = filtered(image, name: "CINoiseReduction", parameters: [
                "inputNoiseLevel": s.noiseReduction / 100 * 0.06,
                "inputSharpness": 0.4,
            ])
        }
        // 선명화
        if s.sharpness > 0.5 {
            image = filtered(image, name: "CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: s.sharpness / 100 * 1.2,
            ])
        }
        // 비네트
        if s.vignette > 0.5 {
            image = filtered(image, name: "CIVignette", parameters: [
                kCIInputIntensityKey: s.vignette / 100 * 1.8,
                kCIInputRadiusKey: 1.6,
            ])
        }
        return image
    }

    /// 피사체/배경을 마스크로 분리해 각각 다른 보정을 적용하고 다시 합성
    static func applyRegionEdits(
        _ image: CIImage,
        subject: RegionAdjustments,
        background: RegionAdjustments,
        mask: CIImage,
        featherSigma: Double
    ) -> CIImage {
        guard !subject.isNeutral || !background.isNeutral else { return image }
        let subjectImage = subject.isNeutral
            ? image
            : applyAdjustments(image, settings: subject.asEditSettings)
        let backgroundImage = background.isNeutral
            ? image
            : applyAdjustments(image, settings: background.asEditSettings)
        var softMask = mask
        if featherSigma > 0.1 {
            softMask = mask.clampedToExtent()
                .applyingGaussianBlur(sigma: featherSigma)
                .cropped(to: mask.extent)
        }
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return image }
        blend.setValue(subjectImage, forKey: kCIInputImageKey)
        blend.setValue(backgroundImage, forKey: kCIInputBackgroundImageKey)
        blend.setValue(softMask, forKey: kCIInputMaskImageKey)
        return blend.outputImage ?? image
    }

    /// 수평 보정 — 기하 변형이므로 심도 합성 이후 마지막에 적용
    static func applyStraighten(_ input: CIImage, degrees: Double) -> CIImage {
        guard abs(degrees) > 0.05 else { return input }
        return filtered(input, name: "CIStraightenFilter", parameters: [
            kCIInputAngleKey: degrees * .pi / 180,
        ])
    }

    /// 색 보정 전체 (자동 보정 + 수동 조정). 기하(수평)·심도는 포함하지 않는다.
    static func renderColor(_ input: CIImage, settings: EditSettings) -> CIImage {
        let base = settings.autoEnhance ? applyAuto(input) : input
        return applyAdjustments(base, settings: settings)
    }

    /// Lanczos 다운스케일 — 긴 변을 maxEdge 이하로 (0 = 원본 유지)
    static func resized(_ input: CIImage, maxEdge: Int) -> CIImage {
        guard maxEdge > 0 else { return input }
        let longEdge = max(input.extent.width, input.extent.height)
        guard longEdge > CGFloat(maxEdge) else { return input }
        let scale = CGFloat(maxEdge) / longEdge
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        return filter.outputImage ?? input
    }

    /// 보정 결과 저장. 원본 EXIF 메타데이터를 최대한 유지한다 (PNG 제외).
    static func export(
        _ image: CIImage,
        originalURL: URL,
        to destination: URL,
        quality: Double = 0.92,
        format: ExportFormat = .jpeg,
        context: CIContext = sharedContext
    ) throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cgImage = context.createCGImage(
            image, from: image.extent, format: .RGBA8, colorSpace: colorSpace
        ) else { throw EnhanceError.renderFailed }

        var properties: [CFString: Any] = [:]
        if let source = CGImageSourceCreateWithURL(originalURL as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            properties = original
        }
        // 픽셀은 이미 회전 적용됨 — orientation 태그를 1로 정규화해 이중 회전 방지
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = cgImage.width
            exif[kCGImagePropertyExifPixelYDimension] = cgImage.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        properties[kCGImageDestinationLossyCompressionQuality] = quality

        let utType: UTType = switch format {
        case .jpeg: .jpeg
        case .heic: .heic
        case .png: .png
        }
        guard let dest = CGImageDestinationCreateWithURL(
            destination as CFURL, utType.identifier as CFString, 1, nil
        ) else { throw EnhanceError.writeFailed }
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EnhanceError.writeFailed }
    }

    /// 한 장 처리: 불러오기 → 전역 색 보정 → (선택) 영역 보정 → (선택) 심도 → 수평 → 저장
    static func processAndWrite(
        source: URL,
        destination: URL,
        settings: EditSettings,
        depth: DepthSettings? = nil,
        watermark: WatermarkSettings? = nil,
        maxEdge: Int = 0,
        format: ExportFormat = .jpeg,
        context: CIContext = sharedContext
    ) throws {
        var image = renderColor(try loadImage(from: source), settings: settings)
        let needsDepth = (depth?.blurRadius ?? 0) > 0.1
        // 마스크는 한 번만 생성해 영역 보정·심도가 공유
        if settings.hasRegionEdits || needsDepth,
           let mask = DepthEffect.subjectMask(ciImage: image) {
            let scale = max(image.extent.width, image.extent.height) / DepthEffect.referenceDimension
            if settings.hasRegionEdits {
                image = applyRegionEdits(
                    image,
                    subject: settings.subject,
                    background: settings.background,
                    mask: mask,
                    featherSigma: settings.regionFeather * scale
                )
            }
            if needsDepth, let depth {
                image = DepthEffect.apply(
                    image: image,
                    mask: mask,
                    sigma: depth.blurRadius * scale,
                    featherSigma: depth.feather * scale
                )
            }
        }
        image = applyStraighten(image, degrees: settings.straighten)
        // 크기 조절은 워터마크 전 — 결과 크기 기준 비율로 얹히도록
        image = resized(image, maxEdge: maxEdge)
        if let watermark {
            image = Watermark.apply(watermark, to: image)
        }
        try? FileManager.default.removeItem(at: destination)
        try export(image, originalURL: source, to: destination, format: format, context: context)
    }
}
