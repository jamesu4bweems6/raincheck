import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

private enum RecordsViewMode: String, CaseIterable, Hashable, Identifiable, Sendable {
    case current = "当前批次"
    case history = "历史记录"

    var id: String { rawValue }
}

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

@MainActor
private enum HistoryTimestampFormatter {
    private static let mmddHHmmss: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private static let fullDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func format(millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000.0)
        return mmddHHmmss.string(from: date)
    }

    static func formatFull(millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000.0)
        return fullDateTime.string(from: date)
    }
}

private enum RecordsDeleteDialogTarget: Equatable {
    case clearCurrent
    case clearAllHistory
    case deleteHistoryEntry(CheckInHistoryEntry)
}

struct RecordsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewMode: RecordsViewMode = .current
    @State private var filter: RecordFilter = .all
    @State private var expandedResultIds: Set<String> = []
    @State private var expandedHistoryIds: Set<String> = []
    @State private var expandedHistoryTraceKeys: Set<String> = []
    @State private var deleteDialogTarget: RecordsDeleteDialogTarget?

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

    private var canShowToolbarActions: Bool {
        switch viewMode {
        case .current:
            return !store.results.isEmpty
        case .history:
            return !store.history.isEmpty
        }
    }

    private func modeLabel(for mode: RecordsViewMode) -> String {
        switch mode {
        case .current:
            return store.results.isEmpty ? mode.rawValue : "\(mode.rawValue) \(store.results.count)"
        case .history:
            return store.history.isEmpty ? mode.rawValue : "\(mode.rawValue) \(store.history.count)"
        }
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

    private var exportCurrentItem: SanitizedReportExportItem {
        let appStore = store
        return SanitizedReportExportItem {
            try await MainActor.run {
                try appStore.exportSanitizedReportURL()
            }
        }
    }

    private var exportAllHistoryItem: SanitizedReportExportItem {
        let appStore = store
        return SanitizedReportExportItem {
            try await MainActor.run {
                try appStore.exportAllHistoryReportURL()
            }
        }
    }

    private func exportHistoryEntryItem(for entry: CheckInHistoryEntry) -> SanitizedReportExportItem {
        let appStore = store
        return SanitizedReportExportItem {
            try await MainActor.run {
                try appStore.exportHistoryEntryReportURL(entry)
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
                            options: RecordsViewMode.allCases,
                            selection: $viewMode
                        ) { mode in
                            modeLabel(for: mode)
                        }

                        switch viewMode {
                        case .current:
                            currentBatchSection
                        case .history:
                            historySection
                        }
                    }
                    .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
                    .padding(.top, 14)
                    .padding(.bottom, LiquidMetrics.scrollBottomPadding)
                }
            }
            .navigationTitle("记录")
            .onAppear {
                if store.results.isEmpty && !store.history.isEmpty {
                    viewMode = .history
                }
            }
            .toolbar {
                if canShowToolbarActions {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        LiquidGlassGroup(spacing: 8) {
                            HStack(spacing: 14) {
                                ShareLink(
                                    item: viewMode == .current ? exportCurrentItem : exportAllHistoryItem,
                                    preview: SharePreview(
                                        viewMode == .current
                                            ? "雨课堂签到记录.json"
                                            : "雨课堂签到历史记录.json"
                                    )
                                ) {
                                    Image(systemName: "square.and.arrow.up")
                                        .frame(minWidth: 30, minHeight: 30)
                                        .accessibilityLabel(
                                            viewMode == .current ? "导出当前批次脱敏记录" : "导出全部脱敏历史记录"
                                        )
                                }

                                Button(role: .destructive) {
                                    deleteDialogTarget = viewMode == .current ? .clearCurrent : .clearAllHistory
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(minWidth: 30, minHeight: 30)
                                        .accessibilityLabel(
                                            viewMode == .current ? "清空当前批次记录" : "清空全部历史记录"
                                        )
                                }
                            }
                        }
                    }
                }
            }
            .confirmationDialog(
                deleteDialogTitle,
                isPresented: Binding(
                    get: { deleteDialogTarget != nil },
                    set: { isPresented in
                        if !isPresented {
                            deleteDialogTarget = nil
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                switch deleteDialogTarget {
                case .clearCurrent:
                    Button("清空当前批次", role: .destructive) {
                        deleteDialogTarget = nil
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                            expandedResultIds.removeAll()
                            store.clearResults()
                        }
                    }
                case .clearAllHistory:
                    Button("清空全部历史", role: .destructive) {
                        deleteDialogTarget = nil
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                            expandedHistoryIds.removeAll()
                            expandedHistoryTraceKeys.removeAll()
                            store.clearHistory()
                        }
                    }
                case .deleteHistoryEntry(let entry):
                    Button("删除该条历史", role: .destructive) {
                        deleteDialogTarget = nil
                        deleteHistoryEntry(entry)
                    }
                case nil:
                    EmptyView()
                }
                Button("取消", role: .cancel) {
                    deleteDialogTarget = nil
                }
            } message: {
                Text(deleteDialogMessage)
            }
        }
    }

    private var deleteDialogTitle: String {
        switch deleteDialogTarget {
        case .clearCurrent:
            return "清空当前批次记录？"
        case .clearAllHistory:
            return "清空全部历史记录（\(store.history.count) 条）？"
        case .deleteHistoryEntry:
            return "删除该条历史记录？"
        case nil:
            return ""
        }
    }

    private var deleteDialogMessage: String {
        switch deleteDialogTarget {
        case .clearCurrent:
            return "仅清除当前批次视图，已持久化的历史记录不受影响。"
        case .clearAllHistory:
            return "将删除本地保存的全部 \(store.history.count) 条签到历史与请求日志，此操作不可撤销。"
        case .deleteHistoryEntry(let entry):
            return "将删除 \(HistoryTimestampFormatter.format(millis: entry.createdAtMs)) 的「\(entry.ticketSummary)」及其全部账号日志，此操作不可撤销。"
        case nil:
            return ""
        }
    }

    // MARK: - Current Batch Mode

    @ViewBuilder
    private var currentBatchSection: some View {
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
            VStack(spacing: 16) {
                LiquidEmptyState(
                    symbol: "doc.text.magnifyingglass",
                    title: store.results.isEmpty ? "暂无当前批次记录" : "当前筛选无记录",
                    message: currentEmptyMessage
                )

                if store.results.isEmpty && !store.history.isEmpty {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                            viewMode = .history
                        }
                    } label: {
                        Label("查看历史记录（\(store.history.count)）", systemImage: "clock.arrow.circlepath")
                    }
                    .liquidSecondaryButtonStyle(
                        minWidth: LiquidMetrics.buttonMinWidth,
                        horizontalPadding: LiquidMetrics.buttonHorizontalPadding,
                        fullWidth: false
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(filteredResults) { result in
                    resultRow(result)
                }
            }
        }
    }

    private var currentEmptyMessage: String {
        if !store.results.isEmpty {
            return "切换上方筛选条件查看其他结果。"
        }
        if !store.history.isEmpty {
            return "当前会话尚未执行新的签到，可切换至「历史记录」查看已保留的 \(store.history.count) 条记录。"
        }
        return "完成签到或演练后，这里会展示各账号的状态与链路详情。"
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
                                    .layoutPriority(1)

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
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(LiquidPalette.subtleSurface(colorScheme), in: Capsule())
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(1)

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

    private func attemptTraceSection(_ result: SignResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !result.host.isEmpty {
                Text("\(LiquidPalette.editionDisplayName(forHost: result.host)) · \(result.host)")
                    .font(.caption2)
                    .foregroundStyle(LiquidPalette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                Button {
                    copyDiagnosticReport(for: result)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2.weight(.semibold))
                        Text("复制诊断")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(LiquidPalette.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
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

                Button(role: .destructive) {
                    deleteCurrentResult(result)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash")
                            .font(.caption2.weight(.semibold))
                        Text("删除")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(destructiveForegroundColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(destructiveFillColor, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(destructiveBorderColor, lineWidth: 0.75)
                            .allowsHitTesting(false)
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

                Spacer(minLength: 0)
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

    // MARK: - Persistent History Mode

    @ViewBuilder
    private var historySection: some View {
        if store.history.isEmpty {
            LiquidEmptyState(
                symbol: "clock.arrow.circlepath",
                title: "暂无历史记录",
                message: "每次扫码或执行签到后都会自动保留脱敏结果与完整请求日志。"
            )
            .padding(.top, 28)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(store.history) { entry in
                    historyEntryCard(entry)
                }
            }
        }
    }

    private func historyEntryCard(_ entry: CheckInHistoryEntry) -> some View {
        let isExpanded = expandedHistoryIds.contains(entry.id)
        let hasFailure = !entry.dryRun && entry.failedCount > 0
        let totalTraces = entry.results.reduce(0) { $0 + $1.attempts.count }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    toggleHistoryExpansion(entry.id)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center, spacing: 6) {
                            Text(HistoryTimestampFormatter.format(millis: entry.createdAtMs))
                                .font(.system(.caption, design: .monospaced).weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(LiquidPalette.secondaryText)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(1)

                            historyKindBadge(for: entry)

                            Spacer(minLength: 0)
                        }

                        Text(entry.ticketSummary)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LiquidPalette.primaryText)
                            .lineLimit(isExpanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let host = entry.ticketHost, !host.isEmpty {
                            Text("\(LiquidPalette.editionDisplayName(forHost: host)) · \(host)")
                                .font(.caption2)
                                .foregroundStyle(LiquidPalette.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        HStack(spacing: 6) {
                            historyOutcomeChips(for: entry)

                            if totalTraces > 0 {
                                Text("\(totalTraces) 条日志")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(LiquidPalette.tertiaryText)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .trailing, spacing: 10) {
                    Button(role: .destructive) {
                        deleteDialogTarget = .deleteHistoryEntry(entry)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(destructiveForegroundColor)
                            .frame(width: 30, height: 30)
                            .background(destructiveFillColor, in: Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(destructiveBorderColor, lineWidth: 0.6)
                                    .allowsHitTesting(false)
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("删除该条历史记录")

                    Button {
                        toggleHistoryExpansion(entry.id)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(LiquidPalette.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .frame(width: 30, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "收起历史详情" : "展开历史详情")
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if isExpanded {
                Divider()
                    .overlay(LiquidPalette.hairline(colorScheme))
                    .padding(.horizontal, 16)

                historyEntryExpandedDetail(entry)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
        }
        .background(
            LiquidPalette.elevatedSurface(colorScheme),
            in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusCard, style: .continuous)
                .strokeBorder(
                    hasFailure
                        ? destructiveBorderColor
                        : LiquidPalette.hairline(colorScheme),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .contextMenu {
            Button {
                copyHistoryReport(for: entry)
            } label: {
                Label("复制全部诊断与日志", systemImage: "doc.on.doc")
            }

            Button(role: .destructive) {
                deleteDialogTarget = .deleteHistoryEntry(entry)
            } label: {
                Label("删除该条历史记录", systemImage: "trash")
            }
        }
    }

    private func historyEntryExpandedDetail(_ entry: CheckInHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            historyTicketMetadataBox(entry)

            historyActionBar(for: entry)

            VStack(alignment: .leading, spacing: 10) {
                LiquidSectionHeader(
                    title: "账号结果与完整日志",
                    trailing: "共 \(entry.totalCount) 账号"
                )

                ForEach(Array(entry.results.enumerated()), id: \.offset) { index, result in
                    historyAccountResultCard(entryId: entry.id, result: result, index: index)
                }
            }
        }
    }

    private func historyTicketMetadataBox(_ entry: CheckInHistoryEntry) -> some View {
        let trimmedRaw = entry.ticketRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = entry.ticketHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLesson = entry.ticketLessonId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCheckin = entry.ticketCheckinId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcomeSummary = entry.dryRun
            ? "演练 \(entry.dryRunCount > 0 ? entry.dryRunCount : entry.totalCount) / 共 \(entry.totalCount) 账号"
            : "成功 \(entry.succeededCount) · 失败 \(entry.failedCount) · 共 \(entry.totalCount) 账号"

        return VStack(alignment: .leading, spacing: 6) {
            Text("脱敏二维码与批次信息")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LiquidPalette.secondaryText)

            metadataRow(
                label: "时间",
                value: HistoryTimestampFormatter.formatFull(millis: entry.createdAtMs)
            )

            metadataRow(
                label: "类型",
                value: entry.dryRun ? "\(entry.ticketKind.displayTitle)（模拟演练）" : entry.ticketKind.displayTitle
            )

            metadataRow(
                label: "结果",
                value: outcomeSummary
            )

            if let trimmedHost, !trimmedHost.isEmpty {
                metadataRow(
                    label: "站点",
                    value: "\(LiquidPalette.editionDisplayName(forHost: trimmedHost)) · \(trimmedHost)"
                )
            }

            if let trimmedLesson, !trimmedLesson.isEmpty {
                metadataRow(label: "课堂 ID", value: trimmedLesson)
            }

            if let trimmedCheckin, !trimmedCheckin.isEmpty {
                metadataRow(label: "签到 ID", value: trimmedCheckin)
            }

            if !trimmedRaw.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("扫码内容")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(LiquidPalette.tertiaryText)

                    Text(trimmedRaw)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(LiquidPalette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LiquidPalette.subtleSurface(colorScheme),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(LiquidPalette.tertiaryText)
                .fixedSize(horizontal: true, vertical: false)

            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(LiquidPalette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
    }

    private func historyActionBar(for entry: CheckInHistoryEntry) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                copyHistoryPill(for: entry, fullWidth: false)
                exportHistoryPill(for: entry, fullWidth: false)
                deleteHistoryPill(for: entry, fullWidth: false)
                Spacer(minLength: 0)
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    copyHistoryPill(for: entry, fullWidth: true)
                    exportHistoryPill(for: entry, fullWidth: true)
                }
                deleteHistoryPill(for: entry, fullWidth: true)
            }
        }
    }

    private func copyHistoryPill(for entry: CheckInHistoryEntry, fullWidth: Bool) -> some View {
        Button {
            copyHistoryReport(for: entry)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "doc.on.doc")
                    .font(.caption.weight(.semibold))
                Text("复制全部诊断")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(LiquidPalette.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 36)
            .background(
                LiquidPalette.accent.opacity(colorScheme == .dark ? 0.16 : 0.10),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        LiquidPalette.accent.opacity(colorScheme == .dark ? 0.30 : 0.22),
                        lineWidth: 0.75
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !fullWidth, vertical: false)
        .layoutPriority(1)
    }

    private func exportHistoryPill(for entry: CheckInHistoryEntry, fullWidth: Bool) -> some View {
        ShareLink(
            item: exportHistoryEntryItem(for: entry),
            preview: SharePreview("雨课堂签到历史-\(entry.createdAtMs).json")
        ) {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up")
                    .font(.caption.weight(.semibold))
                Text("导出 JSON")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(LiquidPalette.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 36)
            .background(LiquidPalette.subtleSurface(colorScheme), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !fullWidth, vertical: false)
        .layoutPriority(1)
    }

    private func deleteHistoryPill(for entry: CheckInHistoryEntry, fullWidth: Bool) -> some View {
        Button(role: .destructive) {
            deleteDialogTarget = .deleteHistoryEntry(entry)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "trash")
                    .font(.caption.weight(.semibold))
                Text("删除")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(destructiveForegroundColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 36)
            .background(destructiveFillColor, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(destructiveBorderColor, lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !fullWidth, vertical: false)
        .layoutPriority(1)
    }

    private func historyAccountResultCard(
        entryId: String,
        result: SignResult,
        index: Int
    ) -> some View {
        let isFailureLike = result.state.isFailureLike
        let traceKeys = result.attempts.indices.map { "\(entryId)|\(result.id)|\(index)|\($0)" }
        let allTracesExpanded = !traceKeys.isEmpty && traceKeys.allSatisfy { expandedHistoryTraceKeys.contains($0) }

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: result.state.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(historyStatusForegroundColor(for: result.state))
                    .frame(width: 28, height: 28)
                    .background(historyStatusFillColor(for: result.state), in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(historyStatusBorderColor(for: result.state), lineWidth: 0.65)
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
                            .foregroundStyle(historyStatusForegroundColor(for: result.state))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(historyStatusFillColor(for: result.state), in: Capsule())
                            .overlay {
                                Capsule()
                                    .strokeBorder(historyStatusBorderColor(for: result.state), lineWidth: 0.6)
                                    .allowsHitTesting(false)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)

                        if !result.host.isEmpty {
                            Text(result.host)
                                .font(.caption2)
                                .foregroundStyle(LiquidPalette.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                Spacer(minLength: 6)

                Text("\(result.elapsedMs) ms")
                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(LiquidPalette.secondaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(LiquidPalette.elevatedSurface(colorScheme), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }

            Text(result.diagnosticReason)
                .font(.footnote)
                .foregroundStyle(isFailureLike ? LiquidPalette.primaryText : LiquidPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            resultDiagnosticChips(for: result, useElevatedNeutralSurface: true)

            if result.attempts.isEmpty {
                Text("无网络请求链路（\(result.diagnosticReason)）")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(LiquidPalette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("请求日志（\(result.attempts.count)）")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(LiquidPalette.secondaryText)

                        Spacer(minLength: 8)

                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                if allTracesExpanded {
                                    expandedHistoryTraceKeys.subtract(traceKeys)
                                } else {
                                    expandedHistoryTraceKeys.formUnion(traceKeys)
                                }
                            }
                        } label: {
                            Text(allTracesExpanded ? "收起全部" : "展开全部")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(LiquidPalette.accent)
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    LiquidPalette.accent.opacity(colorScheme == .dark ? 0.14 : 0.08),
                                    in: Capsule()
                                )
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                    }

                    ForEach(Array(result.attempts.enumerated()), id: \.offset) { attemptIndex, attempt in
                        let traceKey = "\(entryId)|\(result.id)|\(index)|\(attemptIndex)"
                        historyAttemptDisclosure(
                            attempt,
                            index: attemptIndex,
                            traceKey: traceKey
                        )
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LiquidPalette.subtleSurface(colorScheme),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isFailureLike
                        ? destructiveBorderColor
                        : LiquidPalette.hairline(colorScheme),
                    lineWidth: 0.75
                )
                .allowsHitTesting(false)
        }
    }

    private func historyAttemptDisclosure(
        _ attempt: AttemptTrace,
        index: Int,
        traceKey: String
    ) -> some View {
        let isExpanded = expandedHistoryTraceKeys.contains(traceKey)
        let trimmedMessage = attempt.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUrl = attempt.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFinalUrl = attempt.finalUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSnippet = attempt.rawSnippet?.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                    if isExpanded {
                        expandedHistoryTraceKeys.remove(traceKey)
                    } else {
                        expandedHistoryTraceKeys.insert(traceKey)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 6) {
                        Text("#\(index + 1) \(attempt.strategyId) · \(attempt.method)")
                            .font(.system(.caption2, design: .monospaced).weight(.semibold))
                            .foregroundStyle(LiquidPalette.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.80)

                        Spacer(minLength: 4)

                        Text("\(attempt.elapsedMs) ms")
                            .font(.system(.caption2, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(LiquidPalette.tertiaryText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)

                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(LiquidPalette.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
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

                    if !isExpanded && !trimmedMessage.isEmpty {
                        Text(trimmedMessage)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(LiquidPalette.secondaryText)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .overlay(LiquidPalette.hairline(colorScheme))
                    .padding(.horizontal, 10)

                VStack(alignment: .leading, spacing: 7) {
                    if !trimmedMessage.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("响应摘要")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(LiquidPalette.tertiaryText)

                            Text(trimmedMessage)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(LiquidPalette.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }

                    if !trimmedUrl.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("请求 URL")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(LiquidPalette.tertiaryText)

                            Text(trimmedUrl)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(LiquidPalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }

                    if let trimmedFinalUrl, !trimmedFinalUrl.isEmpty, trimmedFinalUrl != trimmedUrl {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("重定向终址")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(LiquidPalette.tertiaryText)

                            Text(trimmedFinalUrl)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(LiquidPalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }

                    if let trimmedSnippet, !trimmedSnippet.isEmpty {
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
                            LiquidPalette.subtleSurface(colorScheme),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.5)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            LiquidPalette.elevatedSurface(colorScheme),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.6)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Shared Badges, Chips & Traces

    private func historyKindBadge(for entry: CheckInHistoryEntry) -> some View {
        let title: String
        let foreground: Color
        let fill: Color
        let border: Color

        if entry.dryRun {
            title = "演练"
            foreground = LiquidPalette.accent
            fill = LiquidPalette.accent.opacity(colorScheme == .dark ? 0.16 : 0.10)
            border = LiquidPalette.accent.opacity(colorScheme == .dark ? 0.30 : 0.22)
        } else {
            switch entry.ticketKind {
            case .dynamicCheckin:
                title = "动态码"
                foreground = LiquidPalette.accent
                fill = LiquidPalette.accent.opacity(colorScheme == .dark ? 0.14 : 0.09)
                border = LiquidPalette.accent.opacity(colorScheme == .dark ? 0.28 : 0.20)
            case .lessonOnly:
                title = "课堂码"
                foreground = LiquidPalette.secondaryText
                fill = LiquidPalette.subtleSurface(colorScheme)
                border = LiquidPalette.hairline(colorScheme)
            case .login:
                title = "登录码"
                foreground = Color.orange
                fill = Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.10)
                border = Color.orange.opacity(colorScheme == .dark ? 0.30 : 0.22)
            case .unknown:
                title = "其他"
                foreground = LiquidPalette.secondaryText
                fill = LiquidPalette.subtleSurface(colorScheme)
                border = LiquidPalette.hairline(colorScheme)
            }
        }

        return Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(fill, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(border, lineWidth: 0.6)
                    .allowsHitTesting(false)
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
    }

    @ViewBuilder
    private func historyOutcomeChips(for entry: CheckInHistoryEntry) -> some View {
        if entry.dryRun || (entry.dryRunCount > 0 && entry.succeededCount == 0 && entry.failedCount == 0) {
            outcomeChip(
                "演练 \(entry.dryRunCount > 0 ? entry.dryRunCount : entry.totalCount)",
                foreground: LiquidPalette.accent,
                fill: LiquidPalette.accent.opacity(colorScheme == .dark ? 0.16 : 0.10),
                border: LiquidPalette.accent.opacity(colorScheme == .dark ? 0.30 : 0.22)
            )
        } else {
            if entry.succeededCount > 0 {
                outcomeChip(
                    "成功 \(entry.succeededCount)",
                    foreground: successForegroundColor,
                    fill: successFillColor,
                    border: successBorderColor
                )
            }

            if entry.failedCount > 0 {
                outcomeChip(
                    "失败 \(entry.failedCount)",
                    foreground: destructiveForegroundColor,
                    fill: destructiveFillColor,
                    border: destructiveBorderColor
                )
            }

            if entry.dryRunCount > 0 {
                outcomeChip(
                    "演练 \(entry.dryRunCount)",
                    foreground: LiquidPalette.accent,
                    fill: LiquidPalette.accent.opacity(colorScheme == .dark ? 0.16 : 0.10),
                    border: LiquidPalette.accent.opacity(colorScheme == .dark ? 0.30 : 0.22)
                )
            }

            if entry.succeededCount == 0 && entry.failedCount == 0 && entry.dryRunCount == 0 {
                outcomeChip(
                    "共 \(entry.totalCount) 项",
                    foreground: LiquidPalette.secondaryText,
                    fill: LiquidPalette.subtleSurface(colorScheme),
                    border: LiquidPalette.hairline(colorScheme)
                )
            }
        }
    }

    private func outcomeChip(
        _ text: String,
        foreground: Color,
        fill: Color,
        border: Color
    ) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(fill, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(border, lineWidth: 0.6)
                    .allowsHitTesting(false)
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
    }

    @ViewBuilder
    private func resultDiagnosticChips(
        for result: SignResult,
        useElevatedNeutralSurface: Bool = false
    ) -> some View {
        let strategy = result.strategyId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasStrategy = !(strategy?.isEmpty ?? true)
        let httpStatus = result.effectiveHttpStatus
        let businessCode = result.effectiveBusinessCode
        let neutralSurface = useElevatedNeutralSurface
            ? LiquidPalette.elevatedSurface(colorScheme)
            : LiquidPalette.subtleSurface(colorScheme)

        if httpStatus != nil || businessCode != nil || hasStrategy {
            HStack(spacing: 6) {
                if let httpStatus {
                    diagnosticMetaChip(
                        httpStatus > 0 ? "HTTP \(httpStatus)" : "网络错误",
                        warning: httpStatus < 0 || httpStatus >= 400,
                        neutralSurface: neutralSurface
                    )
                }

                if let businessCode {
                    diagnosticMetaChip(
                        "code \(businessCode)",
                        warning: businessCode != 0,
                        neutralSurface: neutralSurface
                    )
                }

                if let strategy, !strategy.isEmpty {
                    Text(strategy)
                        .font(.system(.caption2, design: .monospaced).weight(.medium))
                        .foregroundStyle(LiquidPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(neutralSurface, in: Capsule())
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
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
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

    private func diagnosticMetaChip(
        _ text: String,
        warning: Bool,
        neutralSurface: Color? = nil
    ) -> some View {
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
                    : (neutralSurface ?? LiquidPalette.subtleSurface(colorScheme)),
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
            .layoutPriority(1)
    }

    // MARK: - Colors

    private var successForegroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.28, green: 0.84, blue: 0.48)
            : Color(red: 0.09, green: 0.54, blue: 0.27)
    }

    private var successFillColor: Color {
        Color.green.opacity(colorScheme == .dark ? 0.16 : 0.10)
    }

    private var successBorderColor: Color {
        Color.green.opacity(colorScheme == .dark ? 0.32 : 0.22)
    }

    private var destructiveForegroundColor: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.44, blue: 0.40)
            : Color(red: 0.80, green: 0.16, blue: 0.16)
    }

    private var destructiveFillColor: Color {
        Color.red.opacity(colorScheme == .dark ? 0.15 : 0.08)
    }

    private var destructiveBorderColor: Color {
        Color.red.opacity(colorScheme == .dark ? 0.32 : 0.20)
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

    private func historyStatusForegroundColor(for state: SignState) -> Color {
        if state.isSuccessLike {
            return successForegroundColor
        }
        if state.isFailureLike {
            return destructiveForegroundColor
        }
        if state.isDryRun {
            return LiquidPalette.accent
        }
        return LiquidPalette.secondaryText
    }

    private func historyStatusFillColor(for state: SignState) -> Color {
        if state.isSuccessLike {
            return successFillColor
        }
        if state.isFailureLike {
            return destructiveFillColor
        }
        if state.isDryRun {
            return LiquidPalette.accent.opacity(colorScheme == .dark ? 0.16 : 0.10)
        }
        return LiquidPalette.subtleSurface(colorScheme)
    }

    private func historyStatusBorderColor(for state: SignState) -> Color {
        if state.isSuccessLike {
            return successBorderColor
        }
        if state.isFailureLike {
            return destructiveBorderColor
        }
        if state.isDryRun {
            return LiquidPalette.accent.opacity(colorScheme == .dark ? 0.28 : 0.20)
        }
        return LiquidPalette.hairline(colorScheme)
    }

    // MARK: - Actions

    private func toggleHistoryExpansion(_ id: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
            if expandedHistoryIds.contains(id) {
                expandedHistoryIds.remove(id)
            } else {
                expandedHistoryIds.insert(id)
            }
        }
    }

    private func deleteCurrentResult(_ result: SignResult) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
            expandedResultIds.remove(result.id)
            store.deleteResult(id: result.id)
        }
    }

    private func deleteHistoryEntry(_ entry: CheckInHistoryEntry) {
        let prefix = "\(entry.id)|"
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
            expandedHistoryIds.remove(entry.id)
            expandedHistoryTraceKeys = expandedHistoryTraceKeys.filter { !$0.hasPrefix(prefix) }
            store.deleteHistoryEntry(id: entry.id)
        }
    }

    private func copyDiagnosticReport(for result: SignResult) {
        #if canImport(UIKit)
        UIPasteboard.general.string = result.diagnosticReportText
        #endif
        store.showToast(result.state.isFailureLike ? "已复制失败原因与诊断信息" : "已复制诊断信息")
    }

    private func copyHistoryReport(for entry: CheckInHistoryEntry) {
        #if canImport(UIKit)
        UIPasteboard.general.string = entry.diagnosticReportText
        #endif
        store.showToast("已复制历史批次诊断与完整日志")
    }
}
