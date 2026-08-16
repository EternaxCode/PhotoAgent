// Copyright 2026 EternaxCode. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// GUI 없이 터미널에서 실행하는 모드.
/// 사용법: PhotoAgent --cli <원본폴더> [--out <출력폴더>] [--threshold 45] [--dry-run] [--no-sharpen]
enum CLIRunner {
    static func run(arguments: [String]) -> Int32 {
        var source: URL?
        var output: URL?
        var threshold = 45.0
        var dryRun = false
        var sharpen = true

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--cli":
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    source = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
                    index += 1
                }
            case "--out":
                if index + 1 < arguments.count {
                    output = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
                    index += 1
                }
            case "--threshold":
                if index + 1 < arguments.count, let value = Double(arguments[index + 1]) {
                    threshold = value
                    index += 1
                }
            case "--dry-run":
                dryRun = true
            case "--no-sharpen":
                sharpen = false
            default:
                break
            }
            index += 1
        }

        guard let sourceDir = source else {
            print("사용법: PhotoAgent --cli <원본폴더> [--out <출력폴더>] [--threshold 45] [--dry-run] [--no-sharpen]")
            return 2
        }
        let outputDir = output ?? Engine.defaultOutputURL(for: sourceDir)

        let urls = Engine.scanImages(in: sourceDir)
        guard !urls.isEmpty else {
            print("이미지 없음: \(sourceDir.path)")
            return 1
        }
        print("분석 대상 \(urls.count)장 — \(sourceDir.path)")

        // 병렬 분석
        var results = [PhotoMetrics?](repeating: nil, count: urls.count)
        results.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                buffer[i] = Analyzer.analyze(url: urls[i])
            }
        }

        var counts: [Verdict: Int] = [:]
        var jobs: [ExportJob] = []
        let enhancedDir = outputDir.appendingPathComponent("보정완료")
        let rejectedDir = outputDir.appendingPathComponent("제외됨")

        for (i, url) in urls.enumerated() {
            let verdict = Analyzer.verdict(metrics: results[i], blurThreshold: threshold)
            counts[verdict, default: 0] += 1
            let subject = results[i].map { String(format: "%8.1f", $0.subjectSharpness) } ?? "       -"
            let global = results[i].map { String(format: "%8.1f", $0.sharpness) } ?? "       -"
            let aniso = results[i].map { String(format: "%5.1f", $0.anisotropy) } ?? "    -"
            let luma = results[i].map { String(format: "%5.0f", $0.meanLuma) } ?? "    -"
            var tag = verdict.rawValue
            if verdict == .good, let m = results[i], Analyzer.isBokeh(m, blurThreshold: threshold) {
                tag = "양호·아웃포커싱"
            }
            print("  [\(tag)] \(url.lastPathComponent)  피사체\(subject)  전역\(global)  이방비\(aniso)  휘도\(luma)")

            // 제외 대상은 흔들림·노출불량·분석실패 — 초점불량은 의도일 수 있어 보정 대상에 포함
            if verdict == .good || verdict == .defocus {
                let name = url.deletingPathExtension().lastPathComponent + ".jpg"
                jobs.append(ExportJob(
                    source: url,
                    destination: enhancedDir.appendingPathComponent(name),
                    mode: .enhance,
                    verdict: verdict,
                    settings: EditSettings(sharpness: sharpen ? 30 : 0)
                ))
            } else {
                jobs.append(ExportJob(
                    source: url,
                    destination: rejectedDir
                        .appendingPathComponent(verdict.rejectFolderName)
                        .appendingPathComponent(url.lastPathComponent),
                    mode: .copyReject,
                    verdict: verdict
                ))
            }
        }

        print("---")
        let summary = Verdict.allCases
            .compactMap { v in counts[v].map { "\(v.rawValue) \($0)" } }
            .joined(separator: " · ")
        print("판정 요약 (임계값 \(threshold)): \(summary)")

        if dryRun {
            print("dry-run — 파일을 쓰지 않았습니다")
            return 0
        }

        print("내보내기 → \(outputDir.path)")
        let queue = DispatchQueue(label: "export", attributes: .concurrent)
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: 3)
        let failureLock = NSLock()
        var failures: [String] = []

        for job in jobs {
            group.enter()
            semaphore.wait()
            queue.async {
                defer { semaphore.signal(); group.leave() }
                if let error = Engine.performJob(job) {
                    failureLock.lock()
                    failures.append("\(job.source.lastPathComponent): \(error)")
                    failureLock.unlock()
                }
            }
        }
        group.wait()

        let enhanced = jobs.filter { $0.mode == .enhance }.count
        let rejected = jobs.count - enhanced
        print("완료 — 보정 \(enhanced)장 · 제외 정리 \(rejected)장 · 실패 \(failures.count)장")
        for failure in failures { print("  실패: \(failure)") }
        return failures.isEmpty ? 0 : 1
    }
}
