//
//  TelemetryLabView.swift
//  RainCheck
//
//  液态玻璃「报文实验室」：
//   - 顶部液态玻璃状态统计与交互筛选胶囊（全部 / 成功 / 已签到 / 演练 / 需重登 / 已过期 / 拒绝 / 异常）；
//   - 可展开的策略回退时间线（清晰展示每次尝试 URL、HTTP 状态码、业务 code、耗时、消息与原始响应体）；
//   - 「重试失败项」严格沿用 `report.ticket`，绝不混用新扫的码或覆写签到选项；
//   - 导出 JSON 使用 `AppState.cachedExportJSON` 缓存文本（不在 `body` 重绘重新编码），且严格零凭据。
//

import SwiftUI
import UIKit

struct TelemetryLabView: View {
    @EnvironmentObject private var app: AppState
    @Namespace private var filterNamespace

    @State private var activeFilter: SignState? = nil
    @State private var expandedAccountIds: Set<String> = []
    @State private var showExecutionLog: Bool = false

    init() {}

    private var filteredResults: [SignResult] {
        guard let report = app.report else { return [] }
        guard let activeFilter else { return report.results }
        return report.results.filter { $0.state == activeFilter }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidAuroraCanvas(accent: LiquidPalette.cyan)

                ScrollView {
                    VStack(spacing: 18) {
                        if let report = app.report {
                            batchOverviewCard(report)
                            statusFilterStrip(report)
                            resultsTimelineSection(report)
                            executionLogCard
                        } else {
                            emptyTelemetryCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("报文实验室")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if app.report != nil {
                        Button {
                            UIPasteboard.general.string = app.cachedExportJSON
                            LiquidHaptics.notify(.success)
                            app.notice = "已复制零凭据排障 JSON 报告"
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .accessibilityLabel("复制零凭据报告")

                        ShareLink(item: app.cachedExportJSON) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("分享零凭据 JSON 报告")
                    }
                }
            }
            .onValueChange(of: app.report?.finishedAt) { _ in
                activeFilter = nil
                expandedAccountIds.removeAll()
            }
        }
    }

    // MARK: 批次概览与失败重试

    private func batchOverviewCard(_ report: SignBatchReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        LiquidStatusPill(
                            text: report.ticket.kind.displayName,
                            symbol: report.ticket.kind.symbolName,
                            tint: LiquidPalette.cyan
                        )
                        LiquidStatusPill(
                            text: String(format: "%.2fs", Double(report.elapsedMs) / 1000.0),
                            symbol: "stopwatch",
                            tint: LiquidPalette.sapphire
                        )
                    }
                    Text(report.ticket.summary())
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 2)
                    Text("执行时间 \(TimeUtil.format(millis: report.startedAt)) · 导出报告严格零凭据")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                overviewMetric("成功", value: report.successCount, tint: LiquidPalette.emerald)
                overviewMetric("演练", value: report.dryRunCount, tint: LiquidPalette.violet)
                overviewMetric("失败", value: report.failedCount, tint: report.failedCount == 0 ? LiquidPalette.slate : LiquidPalette.coral)
            }

            if report.failedCount > 0 {
                LiquidGlassGroup(spacing: 10) {
                    LiquidGlassActionButton(prominence: .prominent, tint: LiquidPalette.coral) {
                        LiquidHaptics.impact(.medium)
                        Task { await app.retryFailed(from: report) }
                    } label: {
                        Label("用原二维码重试 \(report.failedCount) 个失败账号", systemImage: "arrow.clockwise.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(app.running)
                }
            }
        }
        .padding(18)
        .liquidGlassCard(
            cornerRadius: 26,
            variant: .regular,
            tint: report.failedCount == 0 ? LiquidPalette.emerald : LiquidPalette.coral
        )
    }

    private func overviewMetric(_ label: String, value: Int, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .liquidReadableSurface(cornerRadius: 14)
    }

    // MARK: 液态玻璃统计与筛选胶囊

    private func statusFilterStrip(_ report: SignBatchReport) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LiquidGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    filterChip(
                        title: "全部",
                        count: report.results.count,
                        tint: LiquidPalette.sapphire,
                        selected: activeFilter == nil
                    ) {
                        activeFilter = nil
                    }

                    ForEach(SignState.allCases, id: \.self) { state in
                        let count = report.count(for: state)
                        if count > 0 {
                            filterChip(
                                title: state.displayName,
                                count: count,
                                tint: state.tintColor,
                                selected: activeFilter == state
                            ) {
                                activeFilter = (activeFilter == state) ? nil : state
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func filterChip(
        title: String,
        count: Int,
        tint: Color,
        selected: Bool,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button {
            LiquidHaptics.impact(.light)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                action()
            }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(selected ? Color.white.opacity(0.24) : tint.opacity(0.16)))
            }
            .foregroundStyle(selected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .liquidGlassCapsule(
            variant: selected ? .regular : .clear,
            tint: selected ? tint : nil,
            interactive: true
        )
        .liquidGlassMorphID("filter-\(title)", in: filterNamespace)
    }

    // MARK: 可展开策略回退时间线

    private func resultsTimelineSection(_ report: SignBatchReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LiquidSectionHeader(
                title: "账号策略时间线",
                subtitle: "点击任意账号展开完整请求行、状态码、耗时与响应体",
                trailingBadge: "\(filteredResults.count) / \(report.results.count)",
                tint: LiquidPalette.cyan
            )

            LazyVStack(spacing: 12) {
                ForEach(filteredResults) { result in
                    TelemetryResultCard(
                        result: result,
                        isExpanded: expandedAccountIds.contains(result.accountId),
                        onToggleExpand: {
                            LiquidHaptics.impact(.light)
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                                if expandedAccountIds.contains(result.accountId) {
                                    expandedAccountIds.remove(result.accountId)
                                } else {
                                    expandedAccountIds.insert(result.accountId)
                                }
                            }
                        }
                    )
                }
            }
        }
    }

    // MARK: 运行日志抽屉

    private var executionLogCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    showExecutionLog.toggle()
                }
            } label: {
                HStack {
                    Label("运行日志（\(app.log.count) 条）", systemImage: "terminal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: showExecutionLog ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }

            if showExecutionLog {
                if app.log.isEmpty {
                    Text("暂无日志记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(app.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .liquidReadableSurface(cornerRadius: 20)
    }

    // MARK: 空态卡片

    private var emptyTelemetryCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(LiquidPalette.cyan)
                .padding(18)
                .liquidGlass(.clear, tint: LiquidPalette.cyan, in: Circle())

            Text("暂无报文记录")
                .font(.title3.weight(.bold))

            Text("在「签到台」扫描或粘贴课堂二维码并执行签到（或开启演练模式生成轨迹），此处将呈现每条策略的完整回退时间线。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            LiquidGlassActionButton(prominence: .prominent, tint: LiquidPalette.sapphire) {
                app.activeTab = .studio
            } label: {
                Label("前往签到台", systemImage: "qrcode.viewfinder")
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .liquidGlassCard(cornerRadius: 28, variant: .regular, tint: LiquidPalette.cyan)
    }
}

// MARK: - 单账号结果卡片与策略回退时间线

private struct TelemetryResultCard: View {
    let result: SignResult
    let isExpanded: Bool
    let onToggleExpand: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: { onToggleExpand() }) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: result.state.symbolName)
                            .font(.title3)
                            .foregroundStyle(result.state.tintColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.label)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(result.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(isExpanded ? 6 : 2)
                        }

                        Spacer(minLength: 6)

                        VStack(alignment: .trailing, spacing: 4) {
                            LiquidStatusPill(text: result.state.displayName, tint: result.state.tintColor)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 10) {
                        if let strategy = result.strategy {
                            Label(strategy, systemImage: "arrow.triangle.branch")
                        }
                        if let lessonId = result.lessonId {
                            Label(lessonId, systemImage: "book")
                        }
                        Label("\(result.attempts.count) 次尝试", systemImage: "list.number")
                        Label("\(result.attemptsElapsedMs) ms", systemImage: "clock")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                if result.attempts.isEmpty {
                    Text("没有发起网络尝试（缺少凭据或前置条件不满足）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(result.attempts.enumerated()), id: \.offset) { index, attempt in
                            AttemptTimelineNode(
                                index: index + 1,
                                attempt: attempt,
                                isLast: index == result.attempts.count - 1
                            )
                        }
                    }
                }
            }
        }
        .padding(16)
        .liquidReadableSurface(cornerRadius: 22)
    }
}

private struct AttemptTimelineNode: View {
    let index: Int
    let attempt: StrategyAttempt
    let isLast: Bool

    private var nodeColor: Color {
        if attempt.ok { return LiquidPalette.emerald }
        if let status = attempt.httpStatus, status == 401 || status == 403 { return LiquidPalette.amber }
        if attempt.httpStatus == nil { return LiquidPalette.violet }
        return LiquidPalette.coral
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 4) {
                Text("\(index)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(nodeColor))
                if !isLast {
                    Rectangle()
                        .fill(nodeColor.opacity(0.28))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(attempt.strategy)
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                    Spacer()
                    if let status = attempt.httpStatus {
                        badge("HTTP \(status)", tint: (200...299).contains(status) ? LiquidPalette.emerald : LiquidPalette.coral)
                    }
                    if let code = attempt.code {
                        badge("code \(code)", tint: code == 0 ? LiquidPalette.emerald : LiquidPalette.amber)
                    }
                    badge("\(attempt.elapsedMs)ms", tint: LiquidPalette.slate)
                }

                if let msg = attempt.message?.trimmedNonEmpty {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }

                if !attempt.requestLine.isEmpty {
                    codeBlock(title: "请求", text: attempt.requestLine)
                }
                if let body = attempt.requestBody?.trimmedNonEmpty {
                    codeBlock(title: "请求体", text: body)
                }
                if let response = attempt.responseBody?.trimmedNonEmpty {
                    codeBlock(title: "响应摘要", text: response)
                }
            }
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }

    private func codeBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                }
        }
    }
}
