import SwiftUI
import UniformTypeIdentifiers

private enum RecordFilter: String, CaseIterable, Hashable, Identifiable, Sendable {
    case all = "全部"
    case succeeded = "成功"
    case failed = "失败"

    var id: String { rawValue }
}

private struct SanitizedReportExportItem: Transferable, Sendable {
    let makeURL: @Sendable () async throws -> URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { item in
            let url = try await item.makeURL()
            return SentTransferredFile(url)
        }
    }
}

struct RecordsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var filter: RecordFilter = .all
    @State private var expandedResultIds: Set<String> = []
    @State private var showClearConfirmation = false

    private var filteredResults: [SignResult] {
        switch filter {
        case .all:
            return store.results
        case .succeeded:
            return store.results.filter { $0.state.isSuccessLike }
        case .failed:
            return store.results.filter { !$0.state.isSuccessLike }
        }
    }

    private var failedCount: Int {
        store.results.filter { !$0.state.isSuccessLike }.count
    }

    private var canRetryFailed: Bool {
        failedCount > 0 && store.currentTicket != nil
    }

    private var exportItem: SanitizedReportExportItem {
        let appStore = store
        return SanitizedReportExportItem {
            try await MainActor.run {
                try appStore.exportSanitizedReportURL()
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidCanvas()

                ScrollView {
                    VStack(alignment: .leading, spacing: LiquidMetrics.sectionSpacing) {
                        LiquidSegmentedControl(
                            options: RecordFilter.allCases,
                            selection: $filter
                        ) { option in
                            option.rawValue
                        }

                        if canRetryFailed {
                            Button {
                                store.retryFailed()
                            } label: {
                                Label("重试失败项（\(failedCount)）", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .liquidSecondaryButtonStyle()
                            .disabled(store.isCheckingIn)
                        }

                        if filteredResults.isEmpty {
                            LiquidEmptyState(
                                symbol: "doc.text.magnifyingglass",
                                title: store.results.isEmpty ? "暂无签到记录" : "当前筛选无记录",
                                message: store.results.isEmpty
                                    ? "完成签到或演练后，这里会展示各账号的状态与链路详情。"
                                    : "切换上方筛选条件查看其他结果。"
                            )
                            .padding(.top, 36)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(filteredResults) { result in
                                    resultRow(result)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("记录")
            .toolbar {
                if !store.results.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        LiquidGlassGroup(spacing: 8) {
                            HStack(spacing: 14) {
                                ShareLink(
                                    item: exportItem,
                                    preview: SharePreview("雨课堂签到记录.json")
                                ) {
                                    Image(systemName: "square.and.arrow.up")
                                        .accessibilityLabel("导出脱敏记录")
                                }

                                Button(role: .destructive) {
                                    showClearConfirmation = true
                                } label: {
                                    Image(systemName: "trash")
                                        .accessibilityLabel("清空记录")
                                }
                            }
                        }
                    }
                }
            }
            .confirmationDialog(
                "清空全部签到记录？",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("清空记录", role: .destructive) {
                    expandedResultIds.removeAll()
                    store.clearResults()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func resultRow(_ result: SignResult) -> some View {
        let isExpanded = expandedResultIds.contains(result.id)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                    if isExpanded {
                        expandedResultIds.remove(result.id)
                    } else {
                        expandedResultIds.insert(result.id)
                    }
                }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: result.state.symbolName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(result.state.isSuccessLike ? LiquidPalette.primaryText : LiquidPalette.secondaryText)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.accountLabel)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(LiquidPalette.primaryText)
                            .lineLimit(1)

                        Text(summarySubtitle(for: result))
                            .font(.caption)
                            .foregroundStyle(LiquidPalette.secondaryText)
                            .lineLimit(isExpanded ? 3 : 1)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(result.elapsedMs) ms")
                            .font(.system(.caption, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(LiquidPalette.secondaryText)

                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(LiquidPalette.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .overlay(LiquidPalette.hairline(colorScheme))
                    .padding(.horizontal, 16)

                attemptTraceSection(result)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .background(
            LiquidPalette.elevatedSurface(colorScheme),
            in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusCard, style: .continuous)
                .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 1)
        )
    }

    private func summarySubtitle(for result: SignResult) -> String {
        let trimmed = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == result.state.displayTitle {
            return result.state.displayTitle
        }
        return "\(result.state.displayTitle) · \(trimmed)"
    }

    private func attemptTraceSection(_ result: SignResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if result.attempts.isEmpty {
                Text("无网络请求链路（\(result.state.displayTitle)）")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(LiquidPalette.tertiaryText)
            } else {
                ForEach(Array(result.attempts.enumerated()), id: \.offset) { _, attempt in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(attempt.strategyId) · \(attempt.method)")
                                .font(.system(.caption, design: .monospaced).weight(.medium))
                                .foregroundStyle(LiquidPalette.primaryText)

                            Spacer(minLength: 6)

                            Text(attemptMetaText(attempt))
                                .font(.system(.caption2, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(LiquidPalette.secondaryText)
                        }

                        if !attempt.message.isEmpty {
                            Text(attempt.message)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(LiquidPalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text(attempt.url)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(LiquidPalette.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LiquidPalette.subtleSurface(colorScheme),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
            }
        }
    }

    private func attemptMetaText(_ attempt: AttemptTrace) -> String {
        var parts: [String] = []
        if let httpStatus = attempt.httpStatus {
            parts.append("HTTP \(httpStatus)")
        }
        if let code = attempt.businessCode {
            parts.append("code \(code)")
        }
        parts.append("\(attempt.elapsedMs) ms")
        return parts.joined(separator: " · ")
    }
}
