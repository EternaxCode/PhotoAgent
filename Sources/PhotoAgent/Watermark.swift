import Foundation
import CoreImage
import CoreText
import CoreGraphics
import AppKit

/// 텍스트/이미지 로고 워터마크 합성
enum Watermark {
    /// 워터마크를 이미지 위에 합성. 실패하면 원본 그대로.
    static func apply(_ settings: WatermarkSettings, to image: CIImage) -> CIImage {
        guard settings.isUsable else { return image }
        let maxDimension = max(image.extent.width, image.extent.height)
        guard let overlay = overlayImage(for: settings, maxDimension: maxDimension) else { return image }

        let margin = settings.marginPercent / 100 * maxDimension
        let target = image.extent
        let size = overlay.extent.size

        let x: CGFloat
        switch settings.anchor {
        case .topLeft, .left, .bottomLeft:
            x = target.minX + margin
        case .top, .center, .bottom:
            x = target.midX - size.width / 2
        case .topRight, .right, .bottomRight:
            x = target.maxX - size.width - margin
        }
        // Core Image 좌표계: 원점 좌하단
        let y: CGFloat
        switch settings.anchor {
        case .bottomLeft, .bottom, .bottomRight:
            y = target.minY + margin
        case .left, .center, .right:
            y = target.midY - size.height / 2
        case .topLeft, .top, .topRight:
            y = target.maxY - size.height - margin
        }

        let positioned = overlay.transformed(by: CGAffineTransform(
            translationX: x - overlay.extent.minX,
            y: y - overlay.extent.minY
        ))
        return positioned.composited(over: image).cropped(to: image.extent)
    }

    /// 앵커 배치 전의 워터마크 오버레이(알파 포함) 생성
    static func overlayImage(for settings: WatermarkSettings, maxDimension: CGFloat) -> CIImage? {
        switch settings.kind {
        case .text:
            return textImage(settings, maxDimension: maxDimension)
        case .image:
            return logoImage(settings, maxDimension: maxDimension)
        }
    }

    private static func textImage(_ settings: WatermarkSettings, maxDimension: CGFloat) -> CIImage? {
        let fontSize = max(8, settings.sizePercent / 100 * maxDimension)
        let font = NSFont(name: settings.fontName, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let color = NSColor(
            red: settings.colorRed,
            green: settings.colorGreen,
            blue: settings.colorBlue,
            alpha: settings.opacity
        )
        let attributed = NSAttributedString(string: settings.text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        // 그림자 여유 포함한 캔버스
        let padding = fontSize * 0.25
        let width = Int((bounds.width + padding * 2).rounded(.up))
        let height = Int((bounds.height + padding * 2).rounded(.up))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 가독성용 옅은 그림자
        context.setShadow(
            offset: CGSize(width: 0, height: -fontSize * 0.04),
            blur: fontSize * 0.1,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55 * settings.opacity)
        )
        context.textPosition = CGPoint(x: padding - bounds.minX, y: padding - bounds.minY)
        CTLineDraw(line, context)

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private static func logoImage(_ settings: WatermarkSettings, maxDimension: CGFloat) -> CIImage? {
        let url = URL(fileURLWithPath: settings.imagePath)
        guard var logo = CIImage(contentsOf: url) else { return nil }
        let targetWidth = settings.imageScalePercent / 100 * maxDimension
        guard logo.extent.width > 0 else { return nil }
        let scale = targetWidth / logo.extent.width
        logo = logo.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // 불투명도
        if settings.opacity < 0.999, let matrix = CIFilter(name: "CIColorMatrix") {
            matrix.setValue(logo, forKey: kCIInputImageKey)
            matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: settings.opacity), forKey: "inputAVector")
            logo = matrix.outputImage ?? logo
        }
        return logo
    }
}
