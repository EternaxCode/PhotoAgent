// Copyright 2026 EternaxCode. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit

/// 우측 인스펙터 — 선택한 사진의 정보·판정·빠른 동작
struct InspectorView: View {
    @EnvironmentObject var engine: Engine
    @State private var info: PhotoInfo?
    @State private var thumbnail: CGImage?

    var body: some View {
        Group {
            if let item = engine.selectedItem {
                detail(for: item)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("사진을 클릭하면\n정보가 표시됩니다")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(for item: PhotoItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                thumbnailView(for: item)

                Text(item.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                actionBox(for: item)
                verdictBox(for: item)
                captureBox
                editBox(for: item)
            }
            .padding(12)
        }
        .task(id: item.id) {
            thumbnail = nil
            info = nil
            let url = item.url
            thumbnail = await ThumbnailStore.shared.thumbnail(for: url)
            info = await Task.detached { PhotoInfo.load(url: url) }.value
        }
    }

    private func thumbnailView(for item: PhotoItem) -> some View {
        ZStack {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.12))
                    .frame(height: 160)
                ProgressView().controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(count: 2) { engine.editingItem = item }
        .help("더블클릭: 보정 편집기 열기")
    }

    private func actionBox(for item: PhotoItem) -> some View {
        VStack(spacing: 6) {
            Button {
                engine.editingItem = item
            } label: {
                Label("보정 편집기 열기", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            HStack(spacing: 6) {
                Button {
                    engine.toggleDecision(id: item.id)
                } label: {
                    Label(
                        engine.isIncluded(item) ? "제외하기" : "포함하기",
                        systemImage: engine.isIncluded(item) ? "xmark.circle" : "checkmark.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .help("Finder에서 보기")
            }
        }
    }

    private func verdictBox(for item: PhotoItem) -> some View {
        GroupBox("판정") {
            VStack(alignment: .leading, spacing: 5) {
                let verdict = engine.verdict(for: item)
                HStack(spacing: 6) {
                    Text(verdict.rawValue)
                        .font(.callout.bold())
                        .foregroundStyle(verdict == .good ? Color.green : (verdict == .blurry ? .red : .orange))
                    if let metrics = item.metrics, verdict == .good,
                       Analyzer.isBokeh(metrics, blurThreshold: engine.blurThreshold) {
                        Text("아웃포커싱")
                            .font(.caption)
                            .foregroundStyle(.teal)
                    }
                    if item.userDecision != nil {
                        Text("수동 지정")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                    Text(engine.isIncluded(item) ? "보정 대상" : "제외 대상")
                        .font(.caption)
                        .foregroundStyle(engine.isIncluded(item) ? Color.green : .red)
                }
                if let metrics = item.metrics {
                    Divider()
                    infoRow("피사체 선명도", String(format: "%.1f", metrics.subjectSharpness))
                    infoRow("전역 선명도", String(format: "%.1f", metrics.sharpness))
                    infoRow("블러 이방비", String(format: "%.1f", metrics.anisotropy))
                    infoRow("평균 휘도", String(format: "%.0f / 255", metrics.meanLuma))
                    infoRow("하이라이트 클리핑", String(format: "%.1f%%", metrics.clippedHighlightRatio * 100))
                    infoRow("섀도우 클리핑", String(format: "%.1f%%", metrics.clippedShadowRatio * 100))
                }
                if item.userDecision != nil {
                    Button("자동 판정으로 되돌리기") { engine.resetDecision(id: item.id) }
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var captureBox: some View {
        GroupBox("촬영 정보") {
            VStack(alignment: .leading, spacing: 5) {
                if let info {
                    if let camera = info.camera { infoRow("카메라", camera) }
                    if let lens = info.lensModel { infoRow("렌즈", lens) }
                    if let f = info.fNumber { infoRow("조리개", String(format: "ƒ/%.1f", f)) }
                    if let shutter = info.shutterText { infoRow("셔터", shutter) }
                    if let iso = info.iso { infoRow("ISO", "\(iso)") }
                    if let focal = info.focalLength { infoRow("초점거리", String(format: "%.0fmm", focal)) }
                    if let date = info.dateText { infoRow("촬영일시", date) }
                    if let resolution = info.resolutionText { infoRow("해상도", resolution) }
                    if let size = info.fileSizeText { infoRow("파일 크기", size) }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func editBox(for item: PhotoItem) -> some View {
        GroupBox("편집") {
            VStack(alignment: .leading, spacing: 5) {
                if item.edits == nil && item.depth == nil {
                    Text("편집 없음 — 기본 자동 보정으로 내보냅니다")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if item.edits != nil {
                        Label("수동 보정 적용됨", systemImage: "slider.horizontal.3")
                            .font(.caption)
                    }
                    if item.edits?.hasRegionEdits == true {
                        Label("피사체/배경 영역 보정", systemImage: "person.and.background.dotted")
                            .font(.caption)
                    }
                    if let depth = item.depth {
                        Label(String(format: "심도 효과 (흐림 %.1f)", depth.blurRadius), systemImage: "camera.aperture")
                            .font(.caption)
                    }
                    HStack {
                        Button("설정 복사") { engine.copyEditSettings(from: item.id) }
                            .font(.caption)
                        Button("설정 제거") {
                            engine.setEdits(id: item.id, nil)
                            engine.setDepth(id: item.id, nil)
                        }
                        .font(.caption)
                    }
                }
                if engine.hasCopiedSettings {
                    Button("복사한 설정 붙여넣기") { engine.pasteEditSettings(to: item.id) }
                        .font(.caption)
                }
                Divider()
                HStack {
                    Toggle("워터마크", isOn: Binding(
                        get: { engine.watermarkApplies(to: item) },
                        set: { newValue in
                            engine.setWatermarkOverride(
                                id: item.id,
                                newValue == engine.watermark.enabled ? nil : newValue
                            )
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(!engine.watermark.isUsable)
                    if item.watermarkOverride != nil {
                        Text("개별 설정")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                    Button("설정…") { engine.showWatermarkSheet = true }
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
