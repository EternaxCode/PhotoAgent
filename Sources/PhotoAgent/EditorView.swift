// Copyright 2026 EternaxCode. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CoreImage
import ImageIO

struct HistogramData {
    var red: [Float]
    var green: [Float]
    var blue: [Float]
}

/// 사진 한 장을 전문 보정하는 편집기 — 실시간 미리보기 + RGB 히스토그램
struct EditorView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss

    enum EditScope: String, CaseIterable, Identifiable {
        case global = "전체"
        case subject = "피사체"
        case background = "배경"
        var id: String { rawValue }
    }

    @State private var scope: EditScope = .global
    @State private var itemID: UUID
    @State private var itemURL: URL
    @State private var settings: EditSettings
    @State private var depth: DepthSettings

    @State private var showMask = false
    @State private var showOriginal = false
    @State private var loading = true
    @State private var maskAvailable = true

    @State private var rawBase: CIImage?
    @State private var autoBase: CIImage?       // applyAuto 캐시 — 슬라이더마다 재계산 방지
    @State private var originalPreview: CGImage?
    @State private var subjectMask: CIImage?
    @State private var preview: CGImage?
    @State private var histogram: HistogramData?
    @State private var renderTask: Task<Void, Never>?

    init(item: PhotoItem) {
        _itemID = State(initialValue: item.id)
        _itemURL = State(initialValue: item.url)
        _settings = State(initialValue: item.edits ?? EditSettings())
        _depth = State(initialValue: item.depth ?? DepthSettings(blurRadius: 0, feather: 4))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            HStack(spacing: 0) {
                previewArea
                Divider()
                controlPanel
                    .frame(width: 330)
            }
            Divider()
            bottomBar
                .padding(12)
        }
        .frame(minWidth: 1180, minHeight: 720)
        .task { await load() }
        .onChange(of: settings) { _, _ in scheduleRender() }
        .onChange(of: depth) { _, _ in scheduleRender() }
        .onChange(of: showMask) { _, _ in scheduleRender() }
    }

    // MARK: - 헤더 / 하단

    private var positionText: String {
        guard let index = engine.items.firstIndex(where: { $0.id == itemID }) else { return "" }
        return "\(index + 1) / \(engine.items.count)"
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { move(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .help("이전 사진 (⌘←) — 현재 편집 자동 적용")
            Button { move(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .help("다음 사진 (⌘→) — 현재 편집 자동 적용")
            Text(positionText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(itemURL.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if !maskAvailable {
                Label("피사체 인식 실패 — 심도 사용 불가", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Toggle("원본 비교", isOn: $showOriginal)
                .toggleStyle(.checkbox)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Menu("프리셋") {
                ForEach(EditPreset.all) { preset in
                    Button(preset.name) { settings = preset.settings }
                }
            }
            .frame(width: 110)
            Button("전체 초기화") {
                settings = EditSettings()
                depth = DepthSettings(blurRadius: 0, feather: 4)
            }
            Spacer()
            Text("⌘←/⌘→ 로 이동하면 편집이 자동 적용됩니다")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("취소") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("적용") {
                applyToEngine()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(loading)
        }
    }

    // MARK: - 미리보기

    private var previewArea: some View {
        ZStack {
            Color.black
            if let displayed = showOriginal ? originalPreview : preview {
                Image(decorative: displayed, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay(alignment: .topLeading) {
                        if showOriginal {
                            Text("원본")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.55), in: Capsule())
                                .padding(10)
                        }
                    }
            }
            if loading {
                ProgressView("불러오는 중…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 컨트롤 패널

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let histogram {
                    HistogramView(data: histogram)
                        .frame(height: 88)
                }
                Picker("", selection: $scope) {
                    ForEach(EditScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch scope {
                case .global:
                    globalControls
                case .subject:
                    regionControls(title: "피사체", region: $settings.subject)
                case .background:
                    regionControls(title: "배경", region: $settings.background)
                }

                Text("레이블 더블클릭 = 해당 값 초기화")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var globalControls: some View {
        Toggle("자동 보정 (Apple 자동 향상)", isOn: $settings.autoEnhance)
            .toggleStyle(.checkbox)
        GroupBox("기본") {
            VStack(spacing: 6) {
                sliderRow("노출", value: $settings.exposure, in: -2...2, format: "%+.2f")
                sliderRow("대비", value: $settings.contrast, in: -100...100, format: "%+.0f")
                sliderRow("하이라이트", value: $settings.highlights, in: -100...100, format: "%+.0f")
                sliderRow("섀도우", value: $settings.shadows, in: -100...100, format: "%+.0f")
            }
        }
        GroupBox("색상") {
            VStack(spacing: 6) {
                sliderRow("색온도", value: $settings.temperature, in: -100...100, format: "%+.0f")
                sliderRow("틴트", value: $settings.tint, in: -100...100, format: "%+.0f")
                sliderRow("생동감", value: $settings.vibrance, in: -100...100, format: "%+.0f")
                sliderRow("채도", value: $settings.saturation, in: -100...100, format: "%+.0f")
            }
        }
        GroupBox("디테일") {
            VStack(spacing: 6) {
                sliderRow("선명화", value: $settings.sharpness, in: 0...100)
                sliderRow("노이즈 감소", value: $settings.noiseReduction, in: 0...100)
            }
        }
        GroupBox("효과") {
            VStack(alignment: .leading, spacing: 6) {
                sliderRow("비네트", value: $settings.vignette, in: 0...100)
                sliderRow("수평", value: $settings.straighten, in: -10...10, format: "%+.1f°")
                Divider()
                sliderRow("배경 흐림", value: $depth.blurRadius, in: 0...30, format: "%.1f")
                    .disabled(!maskAvailable)
                sliderRow("경계 부드러움", value: $depth.feather, in: 0...20, format: "%.1f")
                    .disabled(!maskAvailable || depth.blurRadius < 0.1)
                Toggle("피사체 마스크 보기", isOn: $showMask)
                    .toggleStyle(.checkbox)
                    .disabled(!maskAvailable)
            }
        }
    }

    @ViewBuilder
    private func regionControls(title: String, region: Binding<RegionAdjustments>) -> some View {
        if !maskAvailable {
            Label("피사체 인식 실패 — 영역 보정을 쓸 수 없습니다", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Text("\(title) 영역에만 적용됩니다 (Vision 마스크 기반)")
                .font(.caption)
                .foregroundStyle(.secondary)
            GroupBox("기본") {
                VStack(spacing: 6) {
                    sliderRow("노출", value: region.exposure, in: -2...2, format: "%+.2f")
                    sliderRow("대비", value: region.contrast, in: -100...100, format: "%+.0f")
                    sliderRow("하이라이트", value: region.highlights, in: -100...100, format: "%+.0f")
                    sliderRow("섀도우", value: region.shadows, in: -100...100, format: "%+.0f")
                }
            }
            GroupBox("색상") {
                VStack(spacing: 6) {
                    sliderRow("색온도", value: region.temperature, in: -100...100, format: "%+.0f")
                    sliderRow("틴트", value: region.tint, in: -100...100, format: "%+.0f")
                    sliderRow("생동감", value: region.vibrance, in: -100...100, format: "%+.0f")
                    sliderRow("채도", value: region.saturation, in: -100...100, format: "%+.0f")
                }
            }
            GroupBox("디테일") {
                VStack(spacing: 6) {
                    sliderRow("선명화", value: region.sharpness, in: 0...100)
                    sliderRow("노이즈 감소", value: region.noiseReduction, in: 0...100)
                }
            }
            GroupBox("영역 설정") {
                VStack(alignment: .leading, spacing: 6) {
                    sliderRow("경계 부드러움", value: $settings.regionFeather, in: 0...15, format: "%.1f", defaultValue: 3)
                    Toggle("피사체 마스크 보기", isOn: $showMask)
                        .toggleStyle(.checkbox)
                    Button("이 영역 초기화") { region.wrappedValue = RegionAdjustments() }
                        .disabled(region.wrappedValue.isNeutral)
                }
            }
        }
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: String = "%.0f",
        defaultValue: Double = 0
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .frame(width: 78, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { value.wrappedValue = defaultValue }
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: - 상태 전환

    private func applyToEngine() {
        engine.setEdits(id: itemID, settings == EditSettings() ? nil : settings)
        engine.setDepth(id: itemID, depth.blurRadius > 0.1 ? depth : nil)
    }

    private func move(_ delta: Int) {
        applyToEngine()
        guard let index = engine.items.firstIndex(where: { $0.id == itemID }) else { return }
        let newIndex = index + delta
        guard engine.items.indices.contains(newIndex) else { return }
        let next = engine.items[newIndex]
        itemID = next.id
        itemURL = next.url
        settings = next.edits ?? EditSettings()
        depth = next.depth ?? DepthSettings(blurRadius: 0, feather: 4)
        preview = nil
        histogram = nil
        originalPreview = nil
        subjectMask = nil
        rawBase = nil
        autoBase = nil
        maskAvailable = true
        loading = true
        Task { await load() }
    }

    // MARK: - 로드/렌더링

    private func load() async {
        let url = itemURL
        let loaded: (CGImage?, CIImage?, CIImage?, CIImage?) = await Task.detached(priority: .userInitiated) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(DepthEffect.referenceDimension),
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return (nil, nil, nil, nil) }
            let raw = CIImage(cgImage: cgImage)
            let auto = Enhancer.applyAuto(raw)
            let mask = DepthEffect.subjectMask(cgImage: cgImage)
            return (cgImage, raw, auto, mask)
        }.value

        guard itemURL == url else { return }  // 이동으로 무효화된 로드 무시
        originalPreview = loaded.0
        rawBase = loaded.1
        autoBase = loaded.2
        subjectMask = loaded.3
        maskAvailable = loaded.3 != nil
        loading = false
        scheduleRender()
    }

    private func scheduleRender() {
        renderTask?.cancel()
        guard let raw = rawBase, let auto = autoBase else { return }
        let s = settings
        let d = depth
        let mask = subjectMask
        let overlayMask = showMask

        renderTask = Task.detached(priority: .userInitiated) {
            var image = Enhancer.applyAdjustments(s.autoEnhance ? auto : raw, settings: s)
            if let mask, s.hasRegionEdits {
                image = Enhancer.applyRegionEdits(
                    image,
                    subject: s.subject,
                    background: s.background,
                    mask: mask,
                    featherSigma: s.regionFeather
                )
            }
            if let mask, d.blurRadius > 0.1 {
                image = DepthEffect.apply(
                    image: image, mask: mask, sigma: d.blurRadius, featherSigma: d.feather
                )
            }
            if overlayMask, let mask {
                let red = CIImage(color: CIColor(red: 1, green: 0.15, blue: 0.15, alpha: 0.55))
                    .cropped(to: image.extent)
                let tinted = red.composited(over: image)
                if let blend = CIFilter(name: "CIBlendWithMask") {
                    blend.setValue(tinted, forKey: kCIInputImageKey)
                    blend.setValue(image, forKey: kCIInputBackgroundImageKey)
                    blend.setValue(mask, forKey: kCIInputMaskImageKey)
                    image = blend.outputImage ?? image
                }
            }
            image = Enhancer.applyStraighten(image, degrees: s.straighten)
            if Task.isCancelled { return }
            guard let rendered = Enhancer.sharedContext.createCGImage(image, from: image.extent) else { return }
            let hist = Self.computeHistogram(rendered)
            if Task.isCancelled { return }
            await MainActor.run {
                preview = rendered
                histogram = hist
            }
        }
    }

    // MARK: - 히스토그램

    nonisolated static func computeHistogram(_ image: CGImage) -> HistogramData {
        let sampleSize = 160
        var buffer = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: sampleSize,
                height: sampleSize,
                bitsPerComponent: 8,
                bytesPerRow: sampleSize * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        }
        var red = [Float](repeating: 0, count: 256)
        var green = [Float](repeating: 0, count: 256)
        var blue = [Float](repeating: 0, count: 256)
        var offset = 0
        for _ in 0..<(sampleSize * sampleSize) {
            red[Int(buffer[offset])] += 1
            green[Int(buffer[offset + 1])] += 1
            blue[Int(buffer[offset + 2])] += 1
            offset += 4
        }
        // sqrt 스케일 — 피크에 눌리지 않게
        func normalize(_ bins: inout [Float]) {
            let peak = max(bins.max() ?? 1, 1)
            for index in bins.indices {
                bins[index] = (bins[index] / peak).squareRoot()
            }
        }
        normalize(&red)
        normalize(&green)
        normalize(&blue)
        return HistogramData(red: red, green: green, blue: blue)
    }
}

struct HistogramView: View {
    let data: HistogramData

    var body: some View {
        Canvas { context, size in
            context.blendMode = .plusLighter
            for (bins, color) in [
                (data.red, Color(red: 1, green: 0.25, blue: 0.25)),
                (data.green, Color(red: 0.25, green: 1, blue: 0.25)),
                (data.blue, Color(red: 0.35, green: 0.45, blue: 1)),
            ] {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (index, value) in bins.enumerated() {
                    let x = size.width * CGFloat(index) / 255
                    path.addLine(to: CGPoint(x: x, y: size.height * CGFloat(1 - value)))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(color.opacity(0.65)))
            }
        }
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
