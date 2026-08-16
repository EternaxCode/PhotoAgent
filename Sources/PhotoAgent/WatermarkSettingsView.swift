import SwiftUI
import CoreImage
import ImageIO
import AppKit
import UniformTypeIdentifiers

/// 전역 워터마크 설정 시트 — 선택한 사진으로 라이브 미리보기
struct WatermarkSettingsView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss

    @State private var preview: CGImage?
    @State private var baseImage: CIImage?
    @State private var renderTask: Task<Void, Never>?
    @State private var fontFamilies: [String] = []

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                Color(red: engine.watermark.colorRed,
                      green: engine.watermark.colorGreen,
                      blue: engine.watermark.colorBlue)
            },
            set: { newValue in
                let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? .white
                engine.watermark.colorRed = ns.redComponent
                engine.watermark.colorGreen = ns.greenComponent
                engine.watermark.colorBlue = ns.blueComponent
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("워터마크 설정")
                    .font(.headline)
                Spacer()
                Toggle("전역 기본 적용", isOn: $engine.watermark.enabled)
                    .toggleStyle(.switch)
                    .help("켜면 모든 사진에 적용 — 사진별로 끌 수 있습니다")
            }
            .padding(14)
            Divider()
            HStack(spacing: 0) {
                previewArea
                Divider()
                controls
                    .frame(width: 330)
            }
            Divider()
            bottomBar
                .padding(12)
        }
        .frame(minWidth: 1020, minHeight: 620)
        .task {
            fontFamilies = NSFontManager.shared.availableFontFamilies.sorted()
            await loadBase()
        }
        .onChange(of: engine.watermark) { _, _ in scheduleRender() }
    }

    private var previewArea: some View {
        ZStack {
            Color.black
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView("미리보기 준비 중…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("종류", selection: $engine.watermark.kind) {
                    ForEach(WatermarkKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if engine.watermark.kind == .text {
                    GroupBox("텍스트") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("워터마크 문구", text: $engine.watermark.text)
                                .textFieldStyle(.roundedBorder)
                            Picker("폰트", selection: $engine.watermark.fontName) {
                                ForEach(fontFamilies, id: \.self) { family in
                                    Text(family).tag(family)
                                }
                            }
                            HStack {
                                Text("색상")
                                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                                    .labelsHidden()
                                Spacer()
                            }
                            sliderRow("크기", value: $engine.watermark.sizePercent, in: 1...15, format: "%.1f%%")
                        }
                    }
                } else {
                    GroupBox("이미지 로고") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(engine.watermark.imagePath.isEmpty
                                     ? "로고 파일 없음"
                                     : URL(fileURLWithPath: engine.watermark.imagePath).lastPathComponent)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button("선택…") { chooseLogo() }
                            }
                            Text("투명 배경 PNG 권장")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            sliderRow("로고 폭", value: $engine.watermark.imageScalePercent, in: 3...50, format: "%.0f%%")
                        }
                    }
                }

                GroupBox("공통") {
                    VStack(alignment: .leading, spacing: 8) {
                        sliderRow("불투명도", value: $engine.watermark.opacity, in: 0.05...1, format: "%.2f")
                        sliderRow("여백", value: $engine.watermark.marginPercent, in: 0...10, format: "%.1f%%")
                        Text("위치")
                            .font(.caption)
                        anchorGrid
                    }
                }

                Text("크기·여백은 이미지 긴 변 대비 % — 해상도가 달라도 같은 비율로 적용됩니다")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
        }
    }

    private var anchorGrid: some View {
        let rows: [[WatermarkAnchor]] = [
            [.topLeft, .top, .topRight],
            [.left, .center, .right],
            [.bottomLeft, .bottom, .bottomRight],
        ]
        return VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(rows[row]) { anchor in
                        Button {
                            engine.watermark.anchor = anchor
                        } label: {
                            Text(anchor.rawValue)
                                .font(.caption2)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(
                                    engine.watermark.anchor == anchor
                                        ? Color.accentColor.opacity(0.25)
                                        : Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button("모든 사진에 적용") { engine.setWatermarkForAll(true) }
                .disabled(!engine.watermark.isUsable)
                .help("전역 기본을 켜고 사진별 개별 설정을 초기화")
            Button("모두 해제") { engine.setWatermarkForAll(false) }
            Spacer()
            Text("사진별 켜기/끄기: 격자 우클릭 또는 인스펙터")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("완료") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .frame(width: 60, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        if panel.runModal() == .OK, let url = panel.url {
            engine.watermark.imagePath = url.path
        }
    }

    // MARK: - 미리보기

    private func loadBase() async {
        // 선택 사진 우선, 없으면 첫 사진, 그것도 없으면 회색 캔버스
        let url = (engine.selectedItem ?? engine.items.first)?.url
        let base: CIImage? = await Task.detached(priority: .userInitiated) {
            if let url {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1400,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    return CIImage(cgImage: cgImage)
                }
            }
            return CIImage(color: CIColor(red: 0.35, green: 0.37, blue: 0.4))
                .cropped(to: CGRect(x: 0, y: 0, width: 1400, height: 934))
        }.value
        baseImage = base
        scheduleRender()
    }

    private func scheduleRender() {
        renderTask?.cancel()
        guard let base = baseImage else { return }
        let settings = engine.watermark
        renderTask = Task.detached(priority: .userInitiated) {
            let composed = settings.isUsable ? Watermark.apply(settings, to: base) : base
            if Task.isCancelled { return }
            guard let rendered = Enhancer.sharedContext.createCGImage(composed, from: composed.extent) else { return }
            if Task.isCancelled { return }
            await MainActor.run { preview = rendered }
        }
    }
}
