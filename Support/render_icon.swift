// Copyright 2026 EternaxCode. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// 앱 아이콘 렌더러 — Apple HIG 스타일 squircle + 조리개(aperture) 모티프.
// 사용: swift render_icon.swift <출력.png> [크기=1024]
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon_1024.png"
let size = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1024 : 1024
let S = CGFloat(size)

guard let context = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("context") }

// macOS Big Sur 스타일: 1024 캔버스에 약 82% 크기 squircle (시스템 그리드)
let inset = S * 0.09
let iconRect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let cornerRadius = iconRect.width * 0.2237

// 은은한 드롭 섀도우 (Big Sur 아이콘 내장 그림자)
context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -S * 0.005),
    blur: S * 0.02,
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.3)
)
let squircle = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
context.addPath(squircle)
context.setFillColor(CGColor(red: 0.18, green: 0.4, blue: 0.9, alpha: 1))
context.fillPath()
context.restoreGState()

// 배경 그라데이션 (위 밝게 → 아래 깊게)
context.saveGState()
context.addPath(squircle)
context.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [
        CGColor(red: 0.36, green: 0.58, blue: 1.0, alpha: 1),   // #5C94FF
        CGColor(red: 0.15, green: 0.34, blue: 0.78, alpha: 1),  // #2657C7
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: S / 2, y: S - inset),
    end: CGPoint(x: S / 2, y: inset),
    options: []
)

// 상단 유리 하이라이트 — 미묘하게
let highlight = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    highlight,
    start: CGPoint(x: S / 2, y: S - inset),
    end: CGPoint(x: S / 2, y: S * 0.52),
    options: []
)

// 조리개 (aperture) — Feather Icons 좌표계(24pt) 스케일링, 검증된 기하
let center = CGPoint(x: S / 2, y: S / 2)
let R = iconRect.width * 0.30
let strokeWidth = R * 0.16
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
context.setLineWidth(strokeWidth)
context.setLineCap(.round)

func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    // feather 좌표 (12,12) 중심, 반경 10 → 캔버스 좌표 (y 반전)
    CGPoint(x: center.x + (x - 12) / 10 * R, y: center.y - (y - 12) / 10 * R)
}

// 외곽 링
context.addEllipse(in: CGRect(
    x: center.x - R, y: center.y - R, width: R * 2, height: R * 2
))
context.strokePath()

// 블레이드 6개 — 외곽 링 안쪽으로 클립해 링 밖으로 삐져나가지 않게
context.saveGState()
let clipRadius = R - strokeWidth * 1.1
context.addEllipse(in: CGRect(
    x: center.x - clipRadius, y: center.y - clipRadius,
    width: clipRadius * 2, height: clipRadius * 2
))
context.clip()
let blades: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (14.31, 8, 20.05, 17.94),
    (9.69, 8, 21.17, 8),
    (7.38, 12, 13.12, 2.06),
    (9.69, 16, 3.95, 6.06),
    (14.31, 16, 2.83, 16),
    (16.62, 12, 10.88, 21.94),
]
for (x1, y1, x2, y2) in blades {
    context.move(to: pt(x1, y1))
    context.addLine(to: pt(x2, y2))
    context.strokePath()
}
context.restoreGState()
context.restoreGState()

guard let image = context.makeImage() else { fatalError("makeImage") }
let url = URL(fileURLWithPath: outputPath) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("destination")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("finalize") }
print("OK: \(outputPath) (\(size)x\(size))")
