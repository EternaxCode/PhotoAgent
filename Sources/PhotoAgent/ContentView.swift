// Copyright 2026 EternaxCode. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var engine: Engine

    private var isBusy: Bool {
        engine.phase == .analyzing || engine.phase == .exporting
    }

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 245, max: 320)
        } detail: {
            VStack(spacing: 0) {
                photoGrid
                Divider()
                statusBar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            .inspector(isPresented: $engine.showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
            }
        }
        .navigationTitle("PhotoAgent")
        .navigationSubtitle(engine.sourceURL?.lastPathComponent ?? "폴더를 선택하세요")
        .frame(minWidth: 1100, minHeight: 660)
        .toolbar { toolbarContent }
        .sheet(item: $engine.editingItem) { item in
            EditorView(item: item)
                .environmentObject(engine)
        }
        .sheet(isPresented: $engine.showWatermarkSheet) {
            WatermarkSettingsView()
                .environmentObject(engine)
        }
    }

    // MARK: - 툴바

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                engine.startAnalysis()
            } label: {
                Label("분석", systemImage: "magnifyingglass")
            }
            .disabled(engine.sourceURL == nil || isBusy)
            .help("폴더의 사진을 분석해 흔들림·노출을 판정 (⌘R)")

            Button {
                engine.startExport()
            } label: {
                Label("내보내기", systemImage: "wand.and.stars")
            }
            .disabled(!(engine.phase == .analyzed || engine.phase == .done) || engine.outputURL == nil || isBusy)
            .help("보정 대상을 보정해 출력 폴더로 내보내기 (⌘E)")

            Button {
                engine.showWatermarkSheet = true
            } label: {
                Label("워터마크", systemImage: "signature")
            }
            .help("워터마크 설정 (⇧⌘W)")

            Button {
                engine.showInspector.toggle()
            } label: {
                Label("인스펙터", systemImage: "sidebar.right")
            }
            .help("정보 패널 보기/숨기기 (⌥⌘I)")
        }
    }

    // MARK: - 그리드

    private var photoGrid: some View {
        ScrollView {
            if engine.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text("좌측에서 원본 폴더를 확인하고 툴바의 ‘분석’을 누르세요")
                        .foregroundStyle(.secondary)
                    Button {
                        engine.startAnalysis()
                    } label: {
                        Label("분석 시작", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.sourceURL == nil || isBusy)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 140)
            } else if engine.filteredItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: engine.filter.systemImage)
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("‘\(engine.filter.rawValue)’ 필터에 해당하는 사진이 없습니다")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 140)
            } else {
                LazyVGrid(
                    columns: [GridItem(
                        .adaptive(minimum: engine.thumbnailSize, maximum: engine.thumbnailSize * 1.35),
                        spacing: 12
                    )],
                    spacing: 14
                ) {
                    ForEach(engine.filteredItems) { item in
                        PhotoCell(item: item)
                    }
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - 하단 상태

    private var statusBar: some View {
        HStack(spacing: 12) {
            if isBusy {
                ProgressView(value: engine.progress)
                    .frame(width: 200)
            }
            Text(engine.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text("클릭: 선택 · 더블클릭: 편집기 · ✓/✕: 포함 전환")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack(spacing: 5) {
                Image(systemName: "square.grid.3x3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $engine.thumbnailSize, in: 130...260)
                    .frame(width: 110)
                Image(systemName: "square.grid.2x2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help("썸네일 크기")
        }
    }
}

// MARK: - 셀

struct PhotoCell: View {
    @EnvironmentObject var engine: Engine
    let item: PhotoItem
    @State private var thumbnail: CGImage?

    var body: some View {
        let verdict = engine.verdict(for: item)
        let included = engine.isIncluded(item)
        let selected = engine.selectedID == item.id

        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topTrailing) {
                thumbnailView
                    .frame(height: 128)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                included ? Color.green.opacity(0.7) : Color.red.opacity(0.5),
                                lineWidth: item.analysisDone ? 2 : 0
                            )
                    )
                if item.analysisDone {
                    badge(verdict: verdict)
                        .padding(6)
                }
            }
            HStack(spacing: 4) {
                Text(item.url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if item.userDecision != nil {
                    chip("수동", color: .blue)
                }
                if item.edits != nil {
                    chip("편집", color: .orange)
                }
                if item.depth != nil {
                    chip("심도", color: .purple)
                }
                if engine.watermarkApplies(to: item) {
                    chip("WM", color: .cyan)
                }
                Button {
                    engine.toggleDecision(id: item.id)
                } label: {
                    Image(systemName: included ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(included ? .green : .red)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("포함/제외 전환")
            }
            if let metrics = item.metrics {
                Text(String(format: "피사체 %.0f · 이방비 %.1f · 휘도 %.0f",
                            metrics.subjectSharpness, metrics.anisotropy, metrics.meanLuma))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, lineWidth: selected ? 2.5 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            engine.selectedID = item.id
            engine.editingItem = item
        }
        .onTapGesture {
            engine.selectedID = item.id
        }
        .contextMenu {
            Button("보정 편집기 열기…") {
                engine.selectedID = item.id
                engine.editingItem = item
            }
            Divider()
            Button("보정 설정 복사") { engine.copyEditSettings(from: item.id) }
            Button("보정 설정 붙여넣기") { engine.pasteEditSettings(to: item.id) }
                .disabled(!engine.hasCopiedSettings)
            Button("복사한 설정을 보정 대상 전체에 적용") { engine.pasteEditSettingsToAllIncluded() }
                .disabled(!engine.hasCopiedSettings)
            if item.edits != nil || item.depth != nil {
                Button("편집 설정 제거") {
                    engine.setEdits(id: item.id, nil)
                    engine.setDepth(id: item.id, nil)
                }
            }
            Divider()
            Button(engine.watermarkApplies(to: item) ? "워터마크 끄기" : "워터마크 켜기") {
                engine.toggleWatermark(id: item.id)
            }
            .disabled(!engine.watermark.isUsable)
            Divider()
            Button("포함/제외 전환") { engine.toggleDecision(id: item.id) }
            Button("자동 판정으로 되돌리기") { engine.resetDecision(id: item.id) }
            Divider()
            Button("원본 열기") { NSWorkspace.shared.open(item.url) }
            Button("Finder에서 보기") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
        .task(id: item.url) {
            thumbnail = await ThumbnailStore.shared.thumbnail(for: item.url)
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(Color.gray.opacity(0.12))
                ProgressView().controlSize(.small)
            }
        }
    }

    private func badge(verdict: Verdict) -> some View {
        var label = verdict.rawValue
        var color: Color = switch verdict {
        case .good: .green
        case .blurry: .red
        case .defocus: .indigo
        case .dark, .bright: .orange
        case .failed: .gray
        }
        if verdict == .good, let metrics = item.metrics {
            if Analyzer.isSubjectSoft(metrics, blurThreshold: engine.blurThreshold) {
                label = "대상흐림?"
                color = .orange
            } else if Analyzer.isBokeh(metrics, blurThreshold: engine.blurThreshold) {
                label = "아웃포커싱"
                color = .teal
            }
        }
        return Text(label)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.9), in: Capsule())
    }
}
