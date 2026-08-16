import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct PhotoAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine = Engine()

    var body: some Scene {
        WindowGroup("PhotoAgent") {
            ContentView()
                .environmentObject(engine)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // 파일
            CommandGroup(replacing: .newItem) {
                Button("원본 폴더 열기…") { engine.chooseSourceFolder() }
                    .keyboardShortcut("o")
                Button("출력 폴더 선택…") { engine.chooseOutputFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("출력 폴더를 Finder에서 열기") { engine.revealOutput() }
                    .disabled(engine.outputURL == nil)
            }

            // 사진
            CommandMenu("사진") {
                Button("분석 시작") { engine.startAnalysis() }
                    .keyboardShortcut("r")
                    .disabled(engine.sourceURL == nil)
                Button("보정 및 내보내기") { engine.startExport() }
                    .keyboardShortcut("e")
                    .disabled(!(engine.phase == .analyzed || engine.phase == .done))
                Divider()
                Button("보정 편집기 열기") { engine.openEditorForSelection() }
                    .keyboardShortcut(.return)
                    .disabled(engine.selectedID == nil)
                Button("포함/제외 전환") { engine.toggleSelectedDecision() }
                    .keyboardShortcut("k")
                    .disabled(engine.selectedID == nil)
                Button("자동 판정으로 되돌리기") { engine.resetSelectedDecision() }
                    .disabled(engine.selectedID == nil)
                Divider()
                Button("원본을 Finder에서 보기") {
                    if let item = engine.selectedItem {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                }
                .disabled(engine.selectedID == nil)
            }

            // 보정
            CommandMenu("보정") {
                Button("보정 설정 복사") {
                    if let id = engine.selectedID { engine.copyEditSettings(from: id) }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(engine.selectedID == nil)
                Button("보정 설정 붙여넣기") {
                    if let id = engine.selectedID { engine.pasteEditSettings(to: id) }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(engine.selectedID == nil || !engine.hasCopiedSettings)
                Button("복사한 설정을 보정 대상 전체에 적용") {
                    engine.pasteEditSettingsToAllIncluded()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift, .option])
                .disabled(!engine.hasCopiedSettings)
                Divider()
                Button("편집 설정 제거") {
                    if let id = engine.selectedID {
                        engine.setEdits(id: id, nil)
                        engine.setDepth(id: id, nil)
                    }
                }
                .disabled(engine.selectedID == nil)
                Divider()
                Button("워터마크 설정…") { engine.showWatermarkSheet = true }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Button("선택 사진 워터마크 켜기/끄기") {
                    if let id = engine.selectedID { engine.toggleWatermark(id: id) }
                }
                .disabled(engine.selectedID == nil || !engine.watermark.isUsable)
                Button("모든 사진에 워터마크 적용") { engine.setWatermarkForAll(true) }
                    .disabled(!engine.watermark.isUsable)
                Button("모든 사진 워터마크 해제") { engine.setWatermarkForAll(false) }
            }

            // 보기 — 필터 + 인스펙터
            CommandGroup(after: .sidebar) {
                Divider()
                Button("필터: 전체") { engine.filter = .all }
                    .keyboardShortcut("1")
                Button("필터: 보정 대상") { engine.filter = .included }
                    .keyboardShortcut("2")
                Button("필터: 제외 대상") { engine.filter = .excluded }
                    .keyboardShortcut("3")
                Button("필터: 흔들림") { engine.filter = .blurry }
                    .keyboardShortcut("4")
                Button("필터: 편집한 사진") { engine.filter = .edited }
                    .keyboardShortcut("5")
                Divider()
                Button("인스펙터 보기/숨기기") { engine.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}
