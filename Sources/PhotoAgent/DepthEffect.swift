// Copyright 2026 EternaxCode. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoreImage
import Vision

/// 피사체 분리 기반 심도(배경 흐림) 효과
enum DepthEffect {
    /// 흐림 강도의 기준 크기 — 미리보기와 원본 해상도 저장 결과가 같아 보이도록
    /// sigma 를 이 크기 기준으로 정의하고 실제 이미지 크기에 비례해 스케일한다.
    static let referenceDimension = 1400.0

    static func subjectMask(cgImage: CGImage) -> CIImage? {
        subjectMask(handler: VNImageRequestHandler(cgImage: cgImage))
    }

    static func subjectMask(ciImage: CIImage) -> CIImage? {
        subjectMask(handler: VNImageRequestHandler(ciImage: ciImage))
    }

    private static func subjectMask(handler: VNImageRequestHandler) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              !observation.allInstances.isEmpty,
              let buffer = try? observation.generateScaledMaskForImage(
                  forInstances: observation.allInstances, from: handler
              )
        else { return nil }
        return CIImage(cvPixelBuffer: buffer)
    }

    /// 피사체(마스크 밝은 영역)는 유지하고 배경만 가우시안 블러
    static func apply(image: CIImage, mask: CIImage, sigma: Double, featherSigma: Double) -> CIImage {
        guard sigma > 0.1 else { return image }
        var softMask = mask
        if featherSigma > 0.1 {
            softMask = mask.clampedToExtent()
                .applyingGaussianBlur(sigma: featherSigma)
                .cropped(to: mask.extent)
        }
        let blurredBackground = image.clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: image.extent)
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return image }
        blend.setValue(image, forKey: kCIInputImageKey)
        blend.setValue(blurredBackground, forKey: kCIInputBackgroundImageKey)
        blend.setValue(softMask, forKey: kCIInputMaskImageKey)
        return blend.outputImage ?? image
    }
}
