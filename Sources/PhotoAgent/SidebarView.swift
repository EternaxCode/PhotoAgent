import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var engine: Engine

    private var filterSelection: Binding<FilterTab?> {
        Binding(
            get: { engine.filter },
            set: { if let value = $0 { engine.filter = value } }
        )
    }

    var body: some View {
        List(selection: filterSelection) {
            Section("폴더") {
                folderRow(
                    title: "원본",
                    icon: "folder",
                    url: engine.sourceURL,
                    action: { engine.chooseSourceFolder() }
                )
                folderRow(
                    title: "출력",
                    icon: "square.and.arrow.down",
                    url: engine.outputURL,
                    action: { engine.chooseOutputFolder() }
                )
            }

            Section("필터") {
                ForEach(FilterTab.allCases) { tab in
                    HStack {
                        Label(tab.rawValue, systemImage: tab.systemImage)
                        Spacer()
                        if !engine.items.isEmpty {
                            Text("\(engine.count(for: tab))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                    .tag(tab)
                }
            }

            Section("내보내기 설정") {
                Picker("크기", selection: $engine.exportSize) {
                    ForEach(ExportSize.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                Picker("형식", selection: $engine.exportFormat) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
            }

            Section("판정 설정") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("흔들림 기준")
                        Spacer()
                        Text(String(format: "%.0f", engine.blurThreshold))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $engine.blurThreshold, in: 10...150)
                    Text("관대 ← → 엄격 · 판정 즉시 반영")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                Toggle("기본 추가 선명화", isOn: $engine.extraSharpen)
                    .toggleStyle(.checkbox)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 210)
    }

    private func folderRow(title: String, icon: String, url: URL?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: icon)
                Text(url?.path ?? "선택되지 않음")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: action) {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("\(title) 폴더 변경")
        }
        .tag(nil as FilterTab?)
    }
}
