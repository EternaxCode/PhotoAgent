import Foundation
import AppKit
import CoreImage

/// 내보내기 작업 한 건
struct ExportJob: Sendable {
    enum Mode: Sendable {
        case enhance      // 보정 후 JPEG 저장
        case copyReject   // 원본을 제외 폴더로 복사
    }
    let source: URL
    let destination: URL
    let mode: Mode
    let verdict: Verdict
    var settings: EditSettings = EditSettings()
    var depth: DepthSettings? = nil
    var watermark: WatermarkSettings? = nil
    var maxEdge: Int = 0
    var format: ExportFormat = .jpeg
}

struct ExportSummary: Sendable {
    var enhanced = 0
    var rejected = 0
    var failures: [String] = []
}

@MainActor
final class Engine: ObservableObject {
    enum Phase: Equatable {
        case idle, analyzing, analyzed, exporting, done
    }

    @Published var items: [PhotoItem] = []
    @Published var phase: Phase = .idle
    @Published var progress: Double = 0
    @Published var statusText = "폴더를 선택하고 분석을 시작하세요"
    @Published var blurThreshold: Double = 45
    @Published var extraSharpen = true
    @Published var sourceURL: URL?
    @Published var outputURL: URL?

    // UI 상태 — 메뉴바·사이드바·인스펙터가 공유
    @Published var filter: FilterTab = .all
    @Published var selectedID: UUID?
    @Published var editingItem: PhotoItem?
    @Published var showInspector = true
    @Published var thumbnailSize: Double = 170

    // 워터마크 — 전역 설정 1개 + 사진별 override
    @Published var watermark = WatermarkSettings()
    @Published var showWatermarkSheet = false

    // 내보내기 옵션
    @Published var exportSize: ExportSize = .original
    @Published var exportFormat: ExportFormat = .jpeg

    func watermarkApplies(to item: PhotoItem) -> Bool {
        guard watermark.isUsable else { return false }
        return item.watermarkOverride ?? watermark.enabled
    }

    func toggleWatermark(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let current = items[index].watermarkOverride ?? watermark.enabled
        let flipped = !current
        // 전역 기본과 같아지면 override 해제
        items[index].watermarkOverride = (flipped == watermark.enabled) ? nil : flipped
    }

    func setWatermarkOverride(id: UUID, _ value: Bool?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].watermarkOverride = value
    }

    /// 일괄: 전역 기본을 바꾸고 사진별 override 를 모두 초기화
    func setWatermarkForAll(_ enabled: Bool) {
        watermark.enabled = enabled
        for index in items.indices {
            items[index].watermarkOverride = nil
        }
    }

    init() {
        let candidate = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/2026_08_14")
        if FileManager.default.fileExists(atPath: candidate.path) {
            sourceURL = candidate
            outputURL = Self.defaultOutputURL(for: candidate)
        }
    }

    nonisolated static func defaultOutputURL(for source: URL) -> URL {
        source.deletingLastPathComponent()
            .appendingPathComponent(source.lastPathComponent + "_결과")
    }

    func setSource(_ url: URL) {
        sourceURL = url
        outputURL = Self.defaultOutputURL(for: url)
        items = []
        selectedID = nil
        phase = .idle
        statusText = "분석 준비 완료"
    }

    // MARK: - 폴더 선택 / 메뉴 동작

    func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"
        if let sourceURL { panel.directoryURL = sourceURL }
        if panel.runModal() == .OK, let url = panel.url { setSource(url) }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"
        if let outputURL { panel.directoryURL = outputURL.deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url { outputURL = url }
    }

    func revealOutput() {
        guard let outputURL else { return }
        NSWorkspace.shared.open(outputURL)
    }

    var selectedItem: PhotoItem? {
        items.first { $0.id == selectedID }
    }

    func toggleSelectedDecision() {
        guard let selectedID else { return }
        toggleDecision(id: selectedID)
    }

    func resetSelectedDecision() {
        guard let selectedID else { return }
        resetDecision(id: selectedID)
    }

    func openEditorForSelection() {
        editingItem = selectedItem
    }

    // MARK: - 필터

    func matches(_ item: PhotoItem, filter: FilterTab) -> Bool {
        switch filter {
        case .all:
            return true
        case .included:
            return isIncluded(item)
        case .excluded:
            return !isIncluded(item)
        case .bokeh:
            guard let metrics = item.metrics, verdict(for: item) == .good else { return false }
            return Analyzer.isBokeh(metrics, blurThreshold: blurThreshold)
        case .blurry:
            return verdict(for: item) == .blurry
        case .defocus:
            return verdict(for: item) == .defocus
        case .exposure:
            let v = verdict(for: item)
            return v == .dark || v == .bright
        case .edited:
            return item.edits != nil || item.depth != nil
        }
    }

    var filteredItems: [PhotoItem] {
        items.filter { matches($0, filter: filter) }
    }

    func count(for filter: FilterTab) -> Int {
        items.filter { matches($0, filter: filter) }.count
    }

    // MARK: - 판정

    func verdict(for item: PhotoItem) -> Verdict {
        guard item.analysisDone else { return .failed }
        return Analyzer.verdict(metrics: item.metrics, blurThreshold: blurThreshold)
    }

    /// 자동 포함 규칙: 제외 대상은 흔들린 사진(그리고 노출불량·분석실패)뿐.
    /// 아웃포커싱·초점불량은 의도일 수 있으므로 보정 대상에 남긴다.
    func autoIncluded(_ item: PhotoItem) -> Bool {
        let v = verdict(for: item)
        return v == .good || v == .defocus
    }

    func isIncluded(_ item: PhotoItem) -> Bool {
        if let decision = item.userDecision { return decision }
        return autoIncluded(item)
    }

    func toggleDecision(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let currentlyIncluded = isIncluded(items[index])
        let auto = autoIncluded(items[index])
        // 반전값이 자동 판정과 같으면 nil(자동)로 복귀
        let flipped = !currentlyIncluded
        items[index].userDecision = (flipped == auto) ? nil : flipped
    }

    func resetDecision(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].userDecision = nil
    }

    func setDepth(id: UUID, _ settings: DepthSettings?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].depth = settings
    }

    func setEdits(id: UUID, _ settings: EditSettings?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].edits = settings
    }

    /// 사진별 편집이 없을 때 쓰는 기본 설정
    var defaultSettings: EditSettings {
        EditSettings(sharpness: extraSharpen ? 30 : 0)
    }

    // MARK: - 보정 설정 복사/붙여넣기

    @Published private(set) var copiedSettings: EditSettings?
    @Published private(set) var copiedDepth: DepthSettings?
    var hasCopiedSettings: Bool { copiedSettings != nil }

    func copyEditSettings(from id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        copiedSettings = item.edits ?? defaultSettings
        copiedDepth = item.depth
    }

    func pasteEditSettings(to id: UUID) {
        guard let settings = copiedSettings,
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].edits = settings
        items[index].depth = copiedDepth
    }

    func pasteEditSettingsToAllIncluded() {
        guard let settings = copiedSettings else { return }
        for index in items.indices where isIncluded(items[index]) {
            items[index].edits = settings
            items[index].depth = copiedDepth
        }
    }

    var stats: (total: Int, good: Int, blurry: Int, defocus: Int, exposure: Int, failed: Int, included: Int) {
        var good = 0, blurry = 0, defocus = 0, exposure = 0, failed = 0, included = 0
        for item in items where item.analysisDone {
            switch verdict(for: item) {
            case .good: good += 1
            case .blurry: blurry += 1
            case .defocus: defocus += 1
            case .dark, .bright: exposure += 1
            case .failed: failed += 1
            }
            if isIncluded(item) { included += 1 }
        }
        return (items.count, good, blurry, defocus, exposure, failed, included)
    }

    // MARK: - 스캔

    nonisolated static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "webp"
    ]

    nonisolated static func scanImages(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - 분석

    func startAnalysis() {
        guard phase != .analyzing, phase != .exporting, let source = sourceURL else { return }
        let urls = Self.scanImages(in: source)
        items = urls.map { PhotoItem(id: UUID(), url: $0) }
        guard !urls.isEmpty else {
            statusText = "폴더에 이미지가 없습니다"
            phase = .idle
            return
        }
        phase = .analyzing
        progress = 0
        statusText = "분석 중… 0/\(urls.count)"

        Task {
            var completed = 0
            await withTaskGroup(of: (Int, PhotoMetrics?).self) { group in
                var nextIndex = 0
                let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
                func addNext() {
                    guard nextIndex < urls.count else { return }
                    let index = nextIndex
                    nextIndex += 1
                    let url = urls[index]
                    group.addTask { (index, Analyzer.analyze(url: url)) }
                }
                for _ in 0..<min(maxConcurrent, urls.count) { addNext() }
                for await (index, metrics) in group {
                    if index < items.count {
                        items[index].metrics = metrics
                        items[index].analysisDone = true
                    }
                    completed += 1
                    progress = Double(completed) / Double(urls.count)
                    statusText = "분석 중… \(completed)/\(urls.count)"
                    addNext()
                }
            }
            phase = .analyzed
            let s = stats
            statusText = "분석 완료 — 양호 \(s.good) · 흔들림 \(s.blurry) · 초점불량 \(s.defocus) · 노출불량 \(s.exposure)"
                + (s.failed > 0 ? " · 실패 \(s.failed)" : "")
        }
    }

    // MARK: - 내보내기

    func buildJobs(outputDir: URL) -> [ExportJob] {
        let enhancedDir = outputDir.appendingPathComponent("보정완료")
        let rejectedDir = outputDir.appendingPathComponent("제외됨")
        var usedNames = Set<String>()
        var jobs: [ExportJob] = []

        for item in items where item.analysisDone {
            let itemVerdict = verdict(for: item)
            if isIncluded(item) {
                let base = item.url.deletingPathExtension().lastPathComponent
                let ext = exportFormat.fileExtension
                var name = "\(base).\(ext)"
                var counter = 2
                while usedNames.contains(name.lowercased()) {
                    name = "\(base)_\(counter).\(ext)"
                    counter += 1
                }
                usedNames.insert(name.lowercased())
                jobs.append(ExportJob(
                    source: item.url,
                    destination: enhancedDir.appendingPathComponent(name),
                    mode: .enhance,
                    verdict: itemVerdict,
                    settings: item.edits ?? defaultSettings,
                    depth: item.depth,
                    watermark: watermarkApplies(to: item) ? watermark : nil,
                    maxEdge: exportSize.rawValue,
                    format: exportFormat
                ))
            } else {
                let folder = rejectedDir.appendingPathComponent(itemVerdict.rejectFolderName)
                jobs.append(ExportJob(
                    source: item.url,
                    destination: folder.appendingPathComponent(item.url.lastPathComponent),
                    mode: .copyReject,
                    verdict: itemVerdict
                ))
            }
        }
        return jobs
    }

    func startExport() {
        guard phase == .analyzed || phase == .done, let outputDir = outputURL else { return }
        let jobs = buildJobs(outputDir: outputDir)
        guard !jobs.isEmpty else {
            statusText = "내보낼 항목이 없습니다"
            return
        }
        let report = reportText(outputDir: outputDir)
        phase = .exporting
        progress = 0
        statusText = "보정/정리 중… 0/\(jobs.count)"

        Task {
            var completed = 0
            var summary = ExportSummary()
            await withTaskGroup(of: (ExportJob, String?).self) { group in
                var nextIndex = 0
                let maxConcurrent = 3  // 대형 이미지 렌더링 메모리 억제
                func addNext() {
                    guard nextIndex < jobs.count else { return }
                    let job = jobs[nextIndex]
                    nextIndex += 1
                    group.addTask { (job, Self.performJob(job)) }
                }
                for _ in 0..<min(maxConcurrent, jobs.count) { addNext() }
                for await (job, error) in group {
                    if let error {
                        summary.failures.append("\(job.source.lastPathComponent): \(error)")
                    } else if job.mode == .enhance {
                        summary.enhanced += 1
                    } else {
                        summary.rejected += 1
                    }
                    completed += 1
                    progress = Double(completed) / Double(jobs.count)
                    statusText = "보정/정리 중… \(completed)/\(jobs.count)"
                    addNext()
                }
            }

            let reportURL = outputDir.appendingPathComponent("처리결과.txt")
            try? report.write(to: reportURL, atomically: true, encoding: .utf8)

            phase = .done
            var text = "완료 — 보정 \(summary.enhanced)장 · 제외 정리 \(summary.rejected)장"
            if !summary.failures.isEmpty { text += " · 실패 \(summary.failures.count)장" }
            statusText = text
            NSWorkspace.shared.open(outputDir)
        }
    }

    /// 한 건 실행. 성공 시 nil, 실패 시 오류 설명 반환.
    nonisolated static func performJob(_ job: ExportJob) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: job.destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            switch job.mode {
            case .enhance:
                try Enhancer.processAndWrite(
                    source: job.source,
                    destination: job.destination,
                    settings: job.settings,
                    depth: job.depth,
                    watermark: job.watermark,
                    maxEdge: job.maxEdge,
                    format: job.format
                )
            case .copyReject:
                try? fm.removeItem(at: job.destination)
                try fm.copyItem(at: job.source, to: job.destination)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func reportText(outputDir: URL) -> String {
        let s = stats
        var lines: [String] = []
        lines.append("PhotoAgent 처리 결과")
        lines.append("일시 기준 폴더: \(sourceURL?.path ?? "-")")
        lines.append("출력 폴더: \(outputDir.path)")
        lines.append(String(format: "흔들림 판정 임계값: %.0f", blurThreshold))
        lines.append("전체 \(s.total) · 보정 대상 \(s.included) · 흔들림 \(s.blurry) · 초점불량 \(s.defocus) · 노출불량 \(s.exposure) · 분석실패 \(s.failed)")
        lines.append("")
        for item in items where item.analysisDone {
            let v = verdict(for: item)
            let included = isIncluded(item)
            let manual = item.userDecision != nil ? " (수동)" : ""
            let subject = item.metrics.map { String(format: "%.1f", $0.subjectSharpness) } ?? "-"
            let global = item.metrics.map { String(format: "%.1f", $0.sharpness) } ?? "-"
            let aniso = item.metrics.map { String(format: "%.1f", $0.anisotropy) } ?? "-"
            let luma = item.metrics.map { String(format: "%.0f", $0.meanLuma) } ?? "-"
            var tag = included ? "보정" : "제외·\(v.rawValue)"
            if included, let m = item.metrics {
                if v == .defocus { tag = "보정·초점불량" }
                else if Analyzer.isBokeh(m, blurThreshold: blurThreshold) { tag = "보정·아웃포커싱" }
            }
            if included, item.edits != nil { tag += "+편집" }
            if included, item.edits?.hasRegionEdits == true { tag += "+영역" }
            if included, item.depth != nil { tag += "+심도" }
            if included, watermarkApplies(to: item) { tag += "+워터마크" }
            lines.append("[\(tag)\(manual)] \(item.url.lastPathComponent)  피사체 \(subject)  전역 \(global)  이방비 \(aniso)  휘도 \(luma)")
        }
        return lines.joined(separator: "\n")
    }
}
