// Copyright 2026 EternaxCode. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import ImageIO
import CoreGraphics
import Vision

enum Analyzer {
    /// 분석용 다운샘플 크기. 선명도 임계값은 이 크기를 기준으로 보정되어 있다.
    static let analysisMaxPixel = 768
    /// 타일 최대값 통계는 전역 분산보다 체계적으로 높게 나온다 — 슬라이더 값에 곱하는 배율
    static let subjectThresholdScale = 2.0
    /// 이 값 이상이면 방향성 블러(흔들림), 미만이면 등방 블러(초점불량)
    static let motionAnisotropyThreshold = 2.5
    private static let tileSize = 96

    static func analyze(url: URL) -> PhotoMetrics? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        var originalWidth = 0
        var originalHeight = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            originalWidth = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            originalHeight = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: analysisMaxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width >= 3, height >= 3 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // 휘도 통계
        var lumaSum = 0
        var shadowClipped = 0
        var highlightClipped = 0
        for value in pixels {
            lumaSum += Int(value)
            if value <= 8 { shadowClipped += 1 }
            if value >= 247 { highlightClipped += 1 }
        }
        let pixelCount = Double(width * height)

        // Laplacian 맵(선명도) + gradient structure tensor(블러 방향성)를 한 번에 계산
        var laplacianMap = [Float](repeating: 0, count: width * height)
        var ixx = 0.0, iyy = 0.0, ixy = 0.0
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let index = row + x
                let center = Int(pixels[index])
                let left = Int(pixels[index - 1])
                let right = Int(pixels[index + 1])
                let up = Int(pixels[index - width])
                let down = Int(pixels[index + width])
                laplacianMap[index] = Float(4 * center - left - right - up - down)
                let gx = Double(right - left)
                let gy = Double(down - up)
                ixx += gx * gx
                iyy += gy * gy
                ixy += gx * gy
            }
        }

        // structure tensor 고유값 비율 = 블러 이방성.
        // 흔들림은 한 방향으로만 번지므로 비율이 크고, 초점 블러는 등방이라 1 에 가깝다.
        let trace = ixx + iyy
        let discriminant = ((ixx - iyy) * (ixx - iyy) + 4 * ixy * ixy).squareRoot()
        let lambda1 = (trace + discriminant) / 2
        let lambda2 = (trace - discriminant) / 2
        let anisotropy = lambda2 > 1e-9 ? min(99, lambda1 / lambda2) : 99

        let globalSharpness = regionVariance(
            of: laplacianMap, width: width, height: height,
            x0: 1, y0: 1, x1: width - 1, y1: height - 1
        )

        // 타일별 선명도 — 아웃포커싱 사진은 피사체 타일만 선명하고 배경 타일은 흐리다
        var tileVariances: [Double] = []
        var tileY = 1
        while tileY < height - 1 {
            let tileHeight = min(tileSize, height - 1 - tileY)
            var tileX = 1
            while tileX < width - 1 {
                let tileWidth = min(tileSize, width - 1 - tileX)
                if tileWidth >= 48 && tileHeight >= 48 {
                    tileVariances.append(regionVariance(
                        of: laplacianMap, width: width, height: height,
                        x0: tileX, y0: tileY, x1: tileX + tileWidth, y1: tileY + tileHeight
                    ))
                }
                tileX += tileSize
            }
            tileY += tileSize
        }
        let sorted = tileVariances.sorted()
        // 단일 타일 노이즈에 속지 않도록 상위 2개 평균 사용
        let tileTop: Double
        if sorted.count >= 2 {
            tileTop = (sorted[sorted.count - 1] + sorted[sorted.count - 2]) / 2
        } else {
            tileTop = sorted.last ?? globalSharpness
        }
        let tileMedian = sorted.isEmpty ? globalSharpness : sorted[sorted.count / 2]

        // Vision 주목 영역(피사체) 선명도 — 실패하면 nil, 타일 최대값으로 대체됨
        let saliency = saliencySharpness(
            cgImage: cgImage, laplacianMap: laplacianMap, width: width, height: height
        )

        return PhotoMetrics(
            sharpness: globalSharpness,
            tileTopSharpness: tileTop,
            tileMedianSharpness: tileMedian,
            saliencySharpness: saliency,
            anisotropy: anisotropy,
            meanLuma: Double(lumaSum) / pixelCount,
            clippedHighlightRatio: Double(highlightClipped) / pixelCount,
            clippedShadowRatio: Double(shadowClipped) / pixelCount,
            pixelWidth: originalWidth,
            pixelHeight: originalHeight
        )
    }

    /// laplacianMap 의 [x0,x1)×[y0,y1) 영역 분산. 경계(0값)는 호출부에서 제외한다.
    private static func regionVariance(
        of map: [Float], width: Int, height: Int,
        x0: Int, y0: Int, x1: Int, y1: Int
    ) -> Double {
        let clampedX0 = max(1, x0), clampedX1 = min(width - 1, x1)
        let clampedY0 = max(1, y0), clampedY1 = min(height - 1, y1)
        guard clampedX1 - clampedX0 >= 8, clampedY1 - clampedY0 >= 8 else { return 0 }
        var sum = 0.0
        var squareSum = 0.0
        for y in clampedY0..<clampedY1 {
            let row = y * width
            for x in clampedX0..<clampedX1 {
                let value = Double(map[row + x])
                sum += value
                squareSum += value * value
            }
        }
        let count = Double((clampedX1 - clampedX0) * (clampedY1 - clampedY0))
        let mean = sum / count
        return max(0, squareSum / count - mean * mean)
    }

    /// Vision attention saliency 로 피사체 영역을 찾아 그 영역의 선명도를 잰다.
    private static func saliencySharpness(
        cgImage: CGImage, laplacianMap: [Float], width: Int, height: Int
    ) -> Double? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              let objects = observation.salientObjects, !objects.isEmpty
        else { return nil }

        var union = objects[0].boundingBox
        for object in objects.dropFirst() {
            union = union.union(object.boundingBox)
        }
        // Vision 정규화 좌표(원점 좌하단) → 픽셀 버퍼 좌표(원점 좌상단)
        let x0 = Int(union.minX * CGFloat(width))
        let y0 = Int((1 - union.maxY) * CGFloat(height))
        let x1 = Int(union.maxX * CGFloat(width))
        let y1 = Int((1 - union.minY) * CGFloat(height))
        guard x1 - x0 >= 32, y1 - y0 >= 32,
              Double((x1 - x0) * (y1 - y0)) >= 0.02 * Double(width * height)
        else { return nil }
        return regionVariance(of: laplacianMap, width: width, height: height, x0: x0, y0: y0, x1: x1, y1: y1)
    }

    // MARK: - 판정

    /// 지표 → 판정. 노출 문제 → 피사체 선명도 → 블러 방향성 순서로 본다.
    static func verdict(metrics: PhotoMetrics?, blurThreshold: Double) -> Verdict {
        guard let m = metrics else { return .failed }
        if m.meanLuma < 32 && m.clippedShadowRatio > 0.35 { return .dark }
        if m.meanLuma > 218 || m.clippedHighlightRatio > 0.45 { return .bright }
        if m.subjectSharpness < blurThreshold * subjectThresholdScale {
            // 전체가 흐림 — 방향성이 있으면 흔들림, 없으면 초점불량
            return m.anisotropy >= motionAnisotropyThreshold ? .blurry : .defocus
        }
        return .good
    }

    /// 양호 판정 중 의도적 아웃포커싱(피사체 선명 + 배경 흐림)인지
    static func isBokeh(_ m: PhotoMetrics, blurThreshold: Double) -> Bool {
        m.subjectSharpness >= blurThreshold * subjectThresholdScale
            && m.tileMedianSharpness < blurThreshold * 0.8
    }

    /// 배경은 선명한데 Vision 이 찾은 피사체 영역이 흐림 — 초점이 피사체를 빗나갔을 가능성
    static func isSubjectSoft(_ m: PhotoMetrics, blurThreshold: Double) -> Bool {
        guard let saliency = m.saliencySharpness else { return false }
        return saliency < blurThreshold
            && m.tileTopSharpness >= blurThreshold * subjectThresholdScale
    }
}
