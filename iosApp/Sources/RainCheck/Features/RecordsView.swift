import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

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
            return store.results.filter { $0.state.isFailureLike }
        }
    }

    private var succeededCount: Int {
        store.results.filter { $0.state.isSuccessLike }.count
    }

    private var failedCount: Int {
        store.results.filter { $0.state.isFailureLike }.count
    }

    private var canRetryFailed: Bool {
        failedCount > 0 && store.lastBatchTicket != nil
    }

    private func filterLabel(for option: RecordFilter) -> String {
        guard !store.results.isEmpty else {
            return option.rawValue
        }
        switch option {
        case .all:
            return "\(option.rawValue) \(store.results.count)"
        case .succeeded:
            return "\(option.rawValue) \(succeededCount)"
        case .failed:
            return "\(option.rawValue) \(failedCount)"
        }
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
                            filterLabel(for: option)
                        }

                        if canRetryFailed {
                            Button {
                                store.retryFailed()
                            } label: {
                                Label("重试失败项（\(failedCount)）", systemImage: "arrow.clockwise")
                            }
                            .liquidSecondaryButtonStyle(
                                minWidth: nil,
                                horizontalPadding: LiquidMetrics.buttonHorizontalPadding,
                                fullWidth: true
                            )
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
                            .padding(.top, 28)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(filteredResults) { result in
                                    resultRow(result)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
                    .padding(.top, 14)
                    .padding(.bottom, LiquidMetrics.scrollBottomPadding)
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
                                        .frame(minWidth: 30, minHeight: 30)
                                        .accessibilityLabel("导出脱敏记录")
                                }

                                Button(role: .destructive) {
                                    showClearConfirmation = true
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(minWidth: 30, minHeight: 30)
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
        let isFailureLike = result.state.isFailureLike

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
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: result.state.symbolName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(statusForegroundColor(for: result.state))
                            .frame(width: 34, height: 34)
                            .background(statusBadgeFill(for: result.state), in: Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(statusBadgeBorder(for: result.state), lineWidth: 0.75)
                                    .allowsHitTesting(false)
                            }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.accountLabel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(LiquidPalette.primaryText)
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                Text(result.state.displayTitle)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(statusForegroundColor(for: result.state))
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(statusBadgeFill(for: result.state), in: Capsule())
                                    .overlay {
                                        Capsule()
                                            .strokeBorder(statusBadgeBorder(for: result.state), lineWidth: 0.6)
                                            .allowsHitTesting(false)
                                    }
                                    .fixedSize(horizontal: true, vertical: false)

                                if !result.host.isEmpty {
                                    Text(LiquidPalette.editionDisplayName(forHost: result.host))
                                        .font(.caption2)
                                        .foregroundStyle(LiquidPalette.tertiaryText)
                                        .lineLimit(1)
                                }
                            }
                        }

                        Spacer(minLength: 8)

                        VStack(alignment: .trailing, spacing: 6) {
                            Text("\(result.elapsedMs) ms")
                                .font(.system(.caption2, design: .monospaced).weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(LiquidPalette.secondaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(LiquidPalette.subtleSurface(colorScheme), in: Capsule())

                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(LiquidPalette.tertiaryText)
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        }
                    }

                    Text(result.diagnosticReason)
                        .font(.footnote)
                        .foregroundStyle(isFailureLike ? LiquidPalette.primaryText : LiquidPalette.secondaryText)
                        .lineLimit(isExpanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    resultDiagnosticChips(for: result)
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
        .overlay {
            RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusCard, style: .continuous)
                .strokeBorder(
                    isFailureLike
                        ? Color.orange.opacity(colorScheme == .dark ? 0.34 : 0.24)
                        : LiquidPalette.hairline(colorScheme),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func resultDiagnosticChips(for result: SignResult) -> some View {
        let strategy = result.strategyId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasStrategy = !(strategy?.isEmpty ?? true)
        let httpStatus = result.effectiveHttpStatus
        let businessCode = result.effectiveBusinessCode

        if httpStatus != nil || businessCode != nil || hasStrategy {
            HStack(spacing: 6) {
                if let httpStatus {
                    diagnosticMetaChip(
                        httpStatus > 0 ? "HTTP \(httpStatus)" : "网络错误",
                        warning: httpStatus < 0 || httpStatus >= 400
                    )
                }

                if let businessCode {
                    diagnosticMetaChip("code \(businessCode)", warning: businessCode != 0)
                }

                if let strategy, !strategy.isEmpty {
                    Text(strategy)
                        .font(.system(.caption2, design: .monospaced).weight(.medium))
                        .foregroundStyle(LiquidPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(LiquidPalette.subtleSurface(colorScheme), in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.6)
                                .allowsHitTesting(false)
                        }
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func attemptTraceSection(_ result: SignResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                if !result.host.isEmpty {
                    Text("\(LiquidPalette.editionDisplayName(forHost: result.host)) · \(result.host)")
                        .font(.caption2)
                        .foregroundStyle(LiquidPalette.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(result.state.displayTitle)
                        .font(.caption2)
                        .foregroundStyle(LiquidPalette.tertiaryText)
                }

                Spacer(minLength: 8)

                Button {
                    copyDiagnosticReport(for: result)
                } label: {
                    Label("复制诊断", systemImage: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LiquidPalette.accent)
                        .lineLimit(1)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(
                            LiquidPalette.accent.opacity(colorScheme == .dark ? 0.16 : 0.10),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .strokeBorder(
                                    LiquidPalette.accent.opacity(colorScheme == .dark ? 0.28 : 0.20),
                                    lineWidth: 0.75
                                )
                                .allowsHitTesting(false)
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }

            if result.attempts.isEmpty {
                Text("无网络请求链路（\(result.diagnosticReason)）")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(LiquidPalette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(result.attempts.enumerated()), id: \.offset) { index, attempt in
                    attemptTraceCard(attempt, index: index)
                }
            }
        }
    }

    private func attemptTraceCard(_ attempt: AttemptTrace, index: Int) -> some View {
        let trimmedMessage = attempt.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUrl = attempt.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFinalUrl = attempt.finalUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSnippet = attempt.rawSnippet?.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("#\(index + 1) \(attempt.strategyId) · \(attempt.method)")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(LiquidPalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 6)

                Text("\(attempt.elapsedMs) ms")
                    .font(.system(.caption2, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(LiquidPalette.tertiaryText)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if attempt.httpStatus != nil || attempt.businessCode != nil {
                HStack(spacing: 6) {
                    if let httpStatus = attempt.httpStatus {
                        diagnosticMetaChip(
                            httpStatus > 0 ? "HTTP \(httpStatus)" : "网络错误",
                            warning: httpStatus < 0 || httpStatus >= 400
                        )
                    }
                    if let businessCode = attempt.businessCode {
                        diagnosticMetaChip("code \(businessCode)", warning: businessCode != 0)
                    }
                    Spacer(minLength: 0)
                }
            }

            if !trimmedMessage.isEmpty {
                Text(trimmedMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(LiquidPalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Text(trimmedUrl)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(LiquidPalette.tertiaryText)
                .lineLimit(2)
                .truncationMode(.middle)

            if let trimmedFinalUrl, !trimmedFinalUrl.isEmpty, trimmedFinalUrl != trimmedUrl {
                Text("重定向 → \(trimmedFinalUrl)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(LiquidPalette.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            if let trimmedSnippet, !trimmedSnippet.isEmpty, trimmedSnippet != trimmedMessage {
                VStack(alignment: .leading, spacing: 3) {
                    Text("响应片段")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(LiquidPalette.tertiaryText)

                    Text(trimmedSnippet)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(LiquidPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LiquidPalette.elevatedSurface(colorScheme),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LiquidPalette.subtleSurface(colorScheme),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }

    private func diagnosticMetaChip(_ text: String, warning: Bool) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .monospacedDigit()
            .foregroundStyle(warning ? Color.orange : LiquidPalette.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                warning
                    ? Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.10)
                    : LiquidPalette.subtleSurface(colorScheme),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        warning
                            ? Color.orange.opacity(colorScheme == .dark ? 0.34 : 0.24)
                            : LiquidPalette.hairline(colorScheme),
                        lineWidth: 0.6
                    )
                    .allowsHitTesting(false)
            }
            .fixedSize(horizontal: true, vertical: false)
    }

    private func statusForegroundColor(for state: SignState) -> Color {
        if state.isSuccessLike {
            return LiquidPalette.accent
        }
        if state.isFailureLike {
            return Color.orange
        }
        return LiquidPalette.secondaryText
    }

    private func statusBadgeFill(for state: SignState) -> Color {
        if state.isSuccessLike {
            return LiquidPalette.accent.opacity(colorScheme == .dark ? 0.16 : 0.10)
        }
        if state.isFailureLike {
            return Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.10)
        }
        return LiquidPalette.subtleSurface(colorScheme)
    }

    private func statusBadgeBorder(for state: SignState) -> Color {
        if state.isSuccessLike {
            return LiquidPalette.accent.opacity(colorScheme == .dark ? 0.28 : 0.20)
        }
        if state.isFailureLike {
            return Color.orange.opacity(colorScheme == .dark ? 0.34 : 0.24)
        }
        return LiquidPalette.hairline(colorScheme)
    }

    private func copyDiagnosticReport(for result: SignResult) {
        #if canImport(UIKit)
        UIPasteboard.general.string = result.diagnosticReportText
        #endif
        store.showToast(result.state.isFailureLike ? "已复制失败原因与诊断信息" : "已复制诊断信息")
    }
}
