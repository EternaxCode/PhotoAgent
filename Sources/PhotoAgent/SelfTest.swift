import Foundation
import CoreImage

/// 합성 이미지를 만들어 판정·보정 파이프라인을 검증한다.
/// 사용법: PhotoAgent --selftest
enum SelfTest {
    static func run() -> Int32 {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("PhotoAgentSelfTest-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: dir)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("FAIL: 임시 폴더 생성 실패 — \(error)")
            return 1
        }
        defer { try? fm.removeItem(at: dir) }

        let rect = CGRect(x: 0, y: 0, width: 800, height: 600)
        let context = CIContext()
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        func write(_ image: CIImage, name: String) -> URL? {
            let url = dir.appendingPathComponent(name)
            do {
                try context.writeJPEGRepresentation(of: image, to: url, colorSpace: colorSpace)
                return url
            } catch {
                print("FAIL: \(name) 저장 실패 — \(error)")
                return nil
            }
        }

        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?.cropped(to: rect) else {
            print("FAIL: 노이즈 생성 실패")
            return 1
        }
        let gaussianBlurred = noise
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 8)
            .cropped(to: rect)

        // 직선 모션 블러 — 흔들림의 방향성 성질 재현
        var motionBlurred = noise
        if let motion = CIFilter(name: "CIMotionBlur") {
            motion.setValue(noise.clampedToExtent(), forKey: kCIInputImageKey)
            motion.setValue(18.0, forKey: kCIInputRadiusKey)
            motion.setValue(0.7, forKey: kCIInputAngleKey)
            motionBlurred = (motion.outputImage ?? noise).cropped(to: rect)
        }

        // 아웃포커싱 재현: 흐린 배경 + 중앙만 선명한 피사체
        let bokeh = noise
            .cropped(to: CGRect(x: 250, y: 150, width: 300, height: 300))
            .composited(over: gaussianBlurred)
            .cropped(to: rect)

        let dark = CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.03)).cropped(to: rect)
        let bright = CIImage(color: CIColor(red: 0.99, green: 0.99, blue: 0.98)).cropped(to: rect)

        guard
            let sharpURL = write(noise, name: "sharp.jpg"),
            let gaussianURL = write(gaussianBlurred, name: "gaussian.jpg"),
            let motionURL = write(motionBlurred, name: "motion.jpg"),
            let bokehURL = write(bokeh, name: "bokeh.jpg"),
            let darkURL = write(dark, name: "dark.jpg"),
            let brightURL = write(bright, name: "bright.jpg")
        else { return 1 }

        var failed = false
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL"): \(message)")
            if !condition { failed = true }
        }

        let threshold = 45.0

        // 판정 검증
        let verdictCases: [(URL, Verdict, String)] = [
            (sharpURL, .good, "선명한 노이즈"),
            (gaussianURL, .defocus, "가우시안 블러(등방) → 초점불량"),
            (bokehURL, .good, "아웃포커싱 합성(피사체 선명) → 양호"),
            (darkURL, .dark, "암부"),
            (brightURL, .bright, "명부"),
        ]
        for (url, expected, label) in verdictCases {
            let metrics = Analyzer.analyze(url: url)
            let verdict = Analyzer.verdict(metrics: metrics, blurThreshold: threshold)
            let subject = metrics.map { String(format: "%.1f", $0.subjectSharpness) } ?? "-"
            let aniso = metrics.map { String(format: "%.1f", $0.anisotropy) } ?? "-"
            check(verdict == expected,
                  "\(label) → \(verdict.rawValue) (기대 \(expected.rawValue), 피사체 \(subject), 이방비 \(aniso))")
        }

        // 아웃포커싱 플래그 검증
        if let bokehMetrics = Analyzer.analyze(url: bokehURL) {
            check(Analyzer.isBokeh(bokehMetrics, blurThreshold: threshold), "아웃포커싱 플래그 감지")
        } else {
            check(false, "아웃포커싱 지표 분석")
        }
        if let sharpMetrics = Analyzer.analyze(url: sharpURL) {
            check(!Analyzer.isBokeh(sharpMetrics, blurThreshold: threshold), "전면 선명 사진은 아웃포커싱 아님")
        }

        // 이방성 지표 검증 — 흔들림/초점불량 구별의 핵심
        let gaussianAniso = Analyzer.analyze(url: gaussianURL)?.anisotropy ?? -1
        let motionAniso = Analyzer.analyze(url: motionURL)?.anisotropy ?? -1
        check(gaussianAniso >= 0 && gaussianAniso < 2.0,
              String(format: "가우시안 블러 이방비 %.2f < 2.0 (등방)", gaussianAniso))
        check(motionAniso >= Analyzer.motionAnisotropyThreshold,
              String(format: "모션 블러 이방비 %.2f ≥ %.1f (방향성)", motionAniso, Analyzer.motionAnisotropyThreshold))

        // 심도 효과 검증 — 원형 마스크로 중앙 선명·주변 흐림을 만들고 아웃포커싱 시그니처 확인
        if let gradient = CIFilter(name: "CIRadialGradient") {
            gradient.setValue(CIVector(x: 400, y: 300), forKey: "inputCenter")
            gradient.setValue(130.0, forKey: "inputRadius0")
            gradient.setValue(180.0, forKey: "inputRadius1")
            gradient.setValue(CIColor.white, forKey: "inputColor0")
            gradient.setValue(CIColor.black, forKey: "inputColor1")
            if let maskImage = gradient.outputImage?.cropped(to: rect) {
                let depthApplied = DepthEffect.apply(
                    image: noise, mask: maskImage, sigma: 8, featherSigma: 2
                )
                if let depthURL = write(depthApplied, name: "depth.jpg"),
                   let depthMetrics = Analyzer.analyze(url: depthURL) {
                    check(Analyzer.verdict(metrics: depthMetrics, blurThreshold: threshold) == .good
                            && Analyzer.isBokeh(depthMetrics, blurThreshold: threshold),
                          String(format: "심도 효과 → 중앙 선명(%.0f)·배경 흐림(중앙값 %.1f) 시그니처",
                                 depthMetrics.tileTopSharpness, depthMetrics.tileMedianSharpness))
                } else {
                    check(false, "심도 효과 저장/분석")
                }
            } else {
                check(false, "심도 테스트 마스크 생성")
            }
        }

        // 수동 보정 파이프라인 수치 검증
        func averageRGB(_ image: CIImage) -> (r: Double, g: Double, b: Double)? {
            guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(CIVector(cgRect: image.extent), forKey: "inputExtent")
            guard let output = filter.outputImage else { return nil }
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
        }

        let gray = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: rect)
        if let base = averageRGB(gray),
           let brighter = averageRGB(Enhancer.applyAdjustments(gray, settings: EditSettings(exposure: 1.5))) {
            check(brighter.r > base.r + 0.1,
                  String(format: "노출 +1.5EV → 휘도 %.2f→%.2f 상승", base.r, brighter.r))
        } else { check(false, "노출 조정 렌더링") }

        if let warm = averageRGB(Enhancer.applyAdjustments(gray, settings: EditSettings(temperature: 60))) {
            check(warm.r > warm.b + 0.02,
                  String(format: "색온도 +60 → 따뜻하게 (R %.3f > B %.3f)", warm.r, warm.b))
        } else { check(false, "색온도 조정 렌더링") }

        let redImage = CIImage(color: CIColor(red: 0.8, green: 0.25, blue: 0.2)).cropped(to: rect)
        if let mono = averageRGB(Enhancer.applyAdjustments(redImage, settings: EditSettings(saturation: -100))) {
            check(abs(mono.r - mono.g) < 0.03 && abs(mono.g - mono.b) < 0.03,
                  String(format: "채도 -100 → 흑백 (R %.3f G %.3f B %.3f)", mono.r, mono.g, mono.b))
        } else { check(false, "채도 조정 렌더링") }

        // 영역 분리 보정 검증 — 원형 마스크의 안(피사체)만 밝게, 밖(배경)은 유지
        if let gradient2 = CIFilter(name: "CIRadialGradient") {
            gradient2.setValue(CIVector(x: 400, y: 300), forKey: "inputCenter")
            gradient2.setValue(130.0, forKey: "inputRadius0")
            gradient2.setValue(131.0, forKey: "inputRadius1")
            gradient2.setValue(CIColor.white, forKey: "inputColor0")
            gradient2.setValue(CIColor.black, forKey: "inputColor1")
            if let regionMask = gradient2.outputImage?.cropped(to: rect) {
                var subjectAdjust = RegionAdjustments()
                subjectAdjust.exposure = 1.5
                let regionApplied = Enhancer.applyRegionEdits(
                    gray,
                    subject: subjectAdjust,
                    background: RegionAdjustments(),
                    mask: regionMask,
                    featherSigma: 0
                )
                let centerRect = CGRect(x: 360, y: 260, width: 80, height: 80)
                let cornerRect = CGRect(x: 10, y: 10, width: 80, height: 80)
                if let center = averageRGB(regionApplied.cropped(to: centerRect)),
                   let corner = averageRGB(regionApplied.cropped(to: cornerRect)),
                   let baseAvg = averageRGB(gray) {
                    check(center.r > baseAvg.r + 0.1 && abs(corner.r - baseAvg.r) < 0.03,
                          String(format: "영역 보정 — 피사체 %.2f→%.2f 밝아짐, 배경 %.2f 유지",
                                 baseAvg.r, center.r, corner.r))
                } else { check(false, "영역 보정 측정") }
            } else { check(false, "영역 마스크 생성") }
        }

        // 워터마크 검증 — 흰 텍스트를 우하단에 얹으면 그 영역만 밝아진다
        do {
            var wm = WatermarkSettings()
            wm.kind = .text
            wm.text = "© TEST WATERMARK"
            wm.sizePercent = 5
            wm.opacity = 1
            wm.anchor = .bottomRight
            wm.marginPercent = 2
            let marked = Watermark.apply(wm, to: gray)
            // CI 좌표 원점 좌하단 — bottomRight = x 큰 쪽, y 작은 쪽
            let cornerRect = CGRect(x: 560, y: 12, width: 220, height: 50)
            let centerRect = CGRect(x: 300, y: 250, width: 100, height: 100)
            if let corner = averageRGB(marked.cropped(to: cornerRect)),
               let center = averageRGB(marked.cropped(to: centerRect)),
               let baseAvg = averageRGB(gray) {
                check(corner.r > baseAvg.r + 0.05 && abs(center.r - baseAvg.r) < 0.02,
                      String(format: "텍스트 워터마크 — 우하단 %.2f→%.2f 밝아짐, 중앙 %.2f 유지",
                             baseAvg.r, corner.r, center.r))
            } else { check(false, "워터마크 측정") }

            // 이미지 로고 경로
            let logoURL = dir.appendingPathComponent("logo.png")
            let logoImage = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
            if let logoCG = context.createCGImage(logoImage, from: logoImage.extent) {
                let dest = CGImageDestinationCreateWithURL(logoURL as CFURL, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, logoCG, nil)
                CGImageDestinationFinalize(dest)
                var logoWM = WatermarkSettings()
                logoWM.kind = .image
                logoWM.imagePath = logoURL.path
                logoWM.imageScalePercent = 20
                logoWM.opacity = 1
                logoWM.anchor = .topLeft
                logoWM.marginPercent = 2
                let logoMarked = Watermark.apply(logoWM, to: gray)
                // topLeft = x 작은 쪽, y 큰 쪽 (CI 좌표)
                let logoRect = CGRect(x: 20, y: 510, width: 140, height: 60)
                if let logoAvg = averageRGB(logoMarked.cropped(to: logoRect)),
                   let baseAvg = averageRGB(gray) {
                    check(logoAvg.r > baseAvg.r + 0.3,
                          String(format: "이미지 로고 워터마크 — 좌상단 %.2f→%.2f", baseAvg.r, logoAvg.r))
                } else { check(false, "로고 워터마크 측정") }
            } else { check(false, "로고 생성") }
        }

        // 보정 + 저장 경로 검증
        let enhancedURL = dir.appendingPathComponent("enhanced.jpg")
        do {
            try Enhancer.processAndWrite(
                source: sharpURL,
                destination: enhancedURL,
                settings: EditSettings(contrast: 10, vibrance: 10, sharpness: 30, vignette: 20)
            )
            check(fm.fileExists(atPath: enhancedURL.path) && Analyzer.analyze(url: enhancedURL) != nil,
                  "보정 파이프라인 (enhanced.jpg 생성·재분석)")
        } catch {
            check(false, "보정 파이프라인 — \(error)")
        }

        // 크기·포맷 내보내기 (800×600 → 긴 변 500 PNG)
        let resizedURL = dir.appendingPathComponent("resized.png")
        do {
            try Enhancer.processAndWrite(
                source: sharpURL, destination: resizedURL,
                settings: EditSettings(), maxEdge: 500, format: .png
            )
            var width = 0, height = 0
            if let src = CGImageSourceCreateWithURL(resizedURL as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
                height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            }
            check(max(width, height) == 500, "크기·포맷 내보내기 — PNG \(width)×\(height) (긴 변 500)")
        } catch {
            check(false, "크기·포맷 내보내기 — \(error)")
        }

        print(failed ? "SELFTEST FAILED" : "SELFTEST OK")
        return failed ? 1 : 0
    }
}
