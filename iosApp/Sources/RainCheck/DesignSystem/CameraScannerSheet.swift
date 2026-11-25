import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

/// Full-screen AVFoundation QR scanner with serial queue isolation, continuous multi-scan mode,
/// floating session HUD/notifications, pinch/preset zoom, tap-to-focus, photo library QR decoding,
/// iPad orientation support, and Liquid Glass chrome.
struct CameraScannerSheet: View {
    let store: AppStore?
    let continuousMode: Bool
    let selectedAccountCount: Int?
    let isDryRun: Bool
    let onScanned: (String) -> Void
    let onManualPaste: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var viewModel = CameraScannerViewModel()
    @State private var selectedPhotoItem: PhotosPickerItem?
    @Namespace private var zoomGlassNamespace

    init(
        store: AppStore? = nil,
        continuousMode: Bool = false,
        selectedAccountCount: Int? = nil,
        isDryRun: Bool = false,
        onScanned: @escaping (String) -> Void,
        onManualPaste: (() -> Void)? = nil
    ) {
        self.store = store
        self.continuousMode = continuousMode
        self.selectedAccountCount = selectedAccountCount
        self.isDryRun = isDryRun
        self.onScanned = onScanned
        self.onManualPaste = onManualPaste
    }

    private var scannerHintText: String {
        if let count = selectedAccountCount, count > 0 {
            return isDryRun
                ? "对准签到二维码 · 演练 \(count) 个账号"
                : "对准签到二维码 · 扫到即签 \(count) 个账号"
        }
        return "将雨课堂签到二维码置于框内"
    }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                switch viewModel.state {
                case .checking:
                    LiquidCanvas()
                    ProgressView()
                        .tint(LiquidPalette.primaryText)

                case .authorized:
                    liveScannerContent

                case .denied:
                    fallbackStateView(
                        symbol: "camera.viewfinder",
                        title: "需要相机权限",
                        message: "请在系统设置中允许访问相机，或直接从相册选择二维码图片、粘贴链接。",
                        showSettingsButton: true
                    )

                case .unavailable(let message):
                    fallbackStateView(
                        symbol: "camera.metering.unknown",
                        title: "相机不可用",
                        message: message,
                        showSettingsButton: false
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusOverlay
        }
        .onAppear {
            let capturedStore = store
            let stayInScanner = continuousMode
            viewModel.start(
                continuousMode: stayInScanner,
                shouldIgnoreFrames: {
                    capturedStore?.isCheckingIn ?? false
                },
                onScanned: { code in
                    onScanned(code)
                    if !stayInScanner {
                        dismiss()
                    }
                }
            )
        }
        .onDisappear {
            viewModel.stop()
        }
        .task(id: selectedPhotoItem) {
            guard let item = selectedPhotoItem else { return }
            await handleSelectedPhoto(item)
        }
    }

    private var liveScannerContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewRepresentable(
                session: viewModel.session,
                orientationRevision: viewModel.orientationRevision,
                onPinchBegan: {
                    viewModel.beginPinchZoom()
                },
                onPinchChanged: { scale in
                    viewModel.updatePinchZoom(scale: scale)
                },
                onPinchEnded: {
                    viewModel.endPinchZoom()
                },
                onFocusTap: { devicePoint, viewPoint in
                    viewModel.handleFocusTap(devicePoint: devicePoint, viewPoint: viewPoint)
                }
            )
            .ignoresSafeArea()

            if let indicator = viewModel.focusIndicator {
                GeometryReader { _ in
                    FocusReticleView(id: indicator.id)
                        .position(indicator.point)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            viewfinderFrame
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                LiquidGlassGroup(spacing: 12) {
                    HStack(spacing: 10) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.white)
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .liquidGlassCapsule(interactive: true)
                        .accessibilityLabel("关闭扫码")

                        Spacer()

                        PhotosPicker(
                            selection: $selectedPhotoItem,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.subheadline.weight(.semibold))
                                Text("相册")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 20)
                            .frame(minWidth: 102, minHeight: 44)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isDecodingPhoto)
                        .liquidGlassCapsule(interactive: true)
                        .accessibilityLabel("从相册选择二维码图片")

                        if viewModel.hasTorch {
                            Button {
                                viewModel.toggleTorch()
                            } label: {
                                Image(systemName: viewModel.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(viewModel.isTorchOn ? LiquidPalette.accent : Color.white)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .liquidGlassCapsule(interactive: true)
                            .accessibilityLabel(viewModel.isTorchOn ? "关闭手电筒" : "打开手电筒")
                        }
                    }
                }
                .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
                .padding(.top, 16)

                Spacer()

                VStack(spacing: 14) {
                    if viewModel.canZoom {
                        zoomControlBar
                    }

                    LiquidGlassGroup(spacing: 12) {
                        VStack(spacing: 12) {
                            if continuousMode, let store {
                                ScannerBottomHintPill(
                                    store: store,
                                    fallbackDryRun: isDryRun,
                                    fallbackText: scannerHintText
                                )
                            } else {
                                Text(scannerHintText)
                                    .font(.subheadline.weight(.medium))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                                    .liquidGlassCapsule(interactive: false)
                            }

                            if let onManualPaste {
                                Button {
                                    dismiss()
                                    onManualPaste()
                                } label: {
                                    Label("粘贴链接", systemImage: "doc.on.clipboard")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(Color.white)
                                        .padding(.horizontal, LiquidMetrics.buttonHorizontalPadding)
                                        .padding(.vertical, LiquidMetrics.buttonVerticalPadding)
                                        .frame(minWidth: 188, minHeight: LiquidMetrics.buttonMinHeight)
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .liquidGlassCapsule(interactive: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
                .padding(.bottom, 34)
            }
            .environment(\.colorScheme, .dark)
        }
    }

    private var zoomControlBar: some View {
        VStack(spacing: 8) {
            if viewModel.shouldShowLiveZoomBadge {
                let liveText = formattedZoomLabel(viewModel.currentZoomFactor, alwaysShowDecimal: true)
                Text(liveText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(LiquidPalette.darkChromeTrackSurface(), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
                            .allowsHitTesting(false)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .accessibilityLabel("当前缩放倍率 \(liveText)")
            }

            HStack(spacing: 4) {
                ForEach(viewModel.availableZoomPresets, id: \.self) { preset in
                    let isSelected = viewModel.matchedZoomPreset == preset
                    let label = formattedZoomLabel(preset, alwaysShowDecimal: false)

                    Button {
                        viewModel.selectZoomPreset(preset)
                    } label: {
                        Text(label)
                            .font(.subheadline.weight(isSelected ? .bold : .semibold).monospacedDigit())
                            .foregroundStyle(
                                isSelected
                                    ? LiquidPalette.darkChromeSelectedForeground()
                                    : Color.white.opacity(0.92)
                            )
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(
                                minWidth: LiquidMetrics.dockItemMinWidth,
                                minHeight: LiquidMetrics.dockItemMinHeight
                            )
                            .background {
                                if isSelected {
                                    LiquidSelectionPill(tone: .darkOverlay)
                                        .matchedGeometryEffect(id: "scanner.zoom.active", in: zoomGlassNamespace)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .zIndex(isSelected ? 0 : 1)
                    .accessibilityLabel("缩放至 \(label)")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(4)
            .frame(minHeight: LiquidMetrics.dockControlMinHeight)
            .background(LiquidPalette.darkChromeTrackSurface(), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: viewModel.matchedZoomPreset)
        .animation(.easeOut(duration: 0.18), value: viewModel.shouldShowLiveZoomBadge)
    }

    private var statusOverlay: some View {
        let usesDarkChrome = viewModel.state == .authorized
        return VStack(spacing: 10) {
            if continuousMode, let store {
                ScannerSessionOverlayHUD(
                    store: store,
                    usesDarkChrome: usesDarkChrome
                )
            }

            if viewModel.isDecodingPhoto {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(usesDarkChrome ? Color.white : LiquidPalette.primaryText)

                    Text("正在识别二维码…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(usesDarkChrome ? Color.white : LiquidPalette.primaryText)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .liquidGlassCapsule(interactive: false)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .allowsHitTesting(false)
                .accessibilityLabel("正在识别图片中的二维码")
            } else if let toastMessage = viewModel.toastMessage {
                LiquidToastPill(message: toastMessage)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
        .padding(.top, 72)
        .environment(\.colorScheme, usesDarkChrome ? .dark : colorScheme)
        .animation(.easeOut(duration: 0.22), value: viewModel.isDecodingPhoto)
        .animation(.easeOut(duration: 0.22), value: viewModel.toastMessage)
    }

    private var viewfinderFrame: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.36))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .frame(width: 256, height: 256)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()

            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.84), lineWidth: 1.75)
                .frame(width: 256, height: 256)
                .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 2)
        }
        .ignoresSafeArea()
    }

    private func fallbackStateView(
        symbol: String,
        title: String,
        message: String,
        showSettingsButton: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            LiquidCanvas()

            VStack(spacing: 24) {
                Spacer()

                LiquidEmptyState(
                    symbol: symbol,
                    title: title,
                    message: message
                )

                LiquidGlassGroup(spacing: 12) {
                    VStack(spacing: 12) {
                        if showSettingsButton {
                            Button {
                                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                                    openURL(settingsURL)
                                }
                            } label: {
                                Text("前往系统设置")
                            }
                            .liquidPrimaryButtonStyle(
                                minWidth: nil,
                                horizontalPadding: LiquidMetrics.buttonHorizontalPadding,
                                fullWidth: true
                            )

                            fallbackPhotoPickerButton(isPrimary: false)
                        } else {
                            fallbackPhotoPickerButton(isPrimary: true)
                        }

                        if let onManualPaste {
                            Button {
                                dismiss()
                                onManualPaste()
                            } label: {
                                Text("改为粘贴链接")
                            }
                            .liquidSecondaryButtonStyle(
                                minWidth: nil,
                                horizontalPadding: LiquidMetrics.buttonHorizontalPadding,
                                fullWidth: true
                            )
                        }
                    }
                }
                .frame(maxWidth: 340)

                Spacer()
            }
            .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)

            LiquidGlassGroup(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LiquidPalette.primaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .liquidGlassCapsule(interactive: true)
                .accessibilityLabel("关闭扫码")
            }
            .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
            .padding(.top, 16)
        }
    }

    @ViewBuilder
    private func fallbackPhotoPickerButton(isPrimary: Bool) -> some View {
        let picker = PhotosPicker(
            selection: $selectedPhotoItem,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Label("从相册选择", systemImage: "photo.on.rectangle")
        }
        .disabled(viewModel.isDecodingPhoto)

        if isPrimary {
            picker.liquidPrimaryButtonStyle(
                minWidth: nil,
                horizontalPadding: LiquidMetrics.buttonHorizontalPadding,
                fullWidth: true
            )
        } else {
            picker.liquidSecondaryButtonStyle(
                minWidth: nil,
                horizontalPadding: LiquidMetrics.buttonHorizontalPadding,
                fullWidth: true
            )
        }
    }

    @MainActor
    private func handleSelectedPhoto(_ item: PhotosPickerItem) async {
        viewModel.clearToast()
        viewModel.isDecodingPhoto = true
        defer { viewModel.isDecodingPhoto = false }

        let imageData = try? await item.loadTransferable(type: Data.self)
        guard !Task.isCancelled else { return }

        guard let imageData, !imageData.isEmpty else {
            viewModel.showToast("未在所选图片中识别到二维码")
            selectedPhotoItem = nil
            return
        }

        let payload = await QrImageDecoder.decodeAsync(from: imageData)
        guard !Task.isCancelled else { return }

        if let payload, !payload.isEmpty {
            viewModel.deliverPhotoScan(payload)
            if continuousMode {
                selectedPhotoItem = nil
            }
        } else {
            viewModel.showToast("未在所选图片中识别到二维码")
            selectedPhotoItem = nil
        }
    }

    private func formattedZoomLabel(_ factor: CGFloat, alwaysShowDecimal: Bool) -> String {
        let rounded = (Double(factor) * 10.0).rounded() / 10.0
        if !alwaysShowDecimal && abs(rounded - rounded.rounded()) < 0.05 {
            return "\(Int(rounded.rounded()))×"
        }
        return String(format: "%.1f×", rounded)
    }
}

/// Reactive bottom hint capsule for continuous scanner sessions.
private struct ScannerBottomHintPill: View {
    @ObservedObject var store: AppStore
    let fallbackDryRun: Bool
    let fallbackText: String

    private var hintText: String {
        let total = store.scannerSessionTotalCount
        guard total > 0 else { return fallbackText }
        let remaining = store.scannerSessionRemainingAccounts.count
        if remaining == 0 {
            return "本轮 \(total) 个账号已全部成功，点左上角关闭"
        }
        let dryRunActive = store.dryRun || fallbackDryRun
        return dryRunActive
            ? "对准二维码 · 演练剩余 \(remaining)/\(total) 个账号"
            : "对准签到二维码 · 剩余 \(remaining)/\(total) 个账号待签"
    }

    var body: some View {
        Text(hintText)
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .liquidGlassCapsule(interactive: false)
    }
}

/// Reactive floating session HUD + live progress + dark-chrome notification card inside `CameraScannerSheet`.
private struct ScannerSessionOverlayHUD: View {
    @ObservedObject var store: AppStore
    let usesDarkChrome: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let total = store.scannerSessionTotalCount
        let succeeded = store.scannerSessionSucceededCount
        let remaining = store.scannerSessionRemainingAccounts.count

        VStack(spacing: 10) {
            if total > 0 {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        store.presentScannerSessionStatusNotification()
                    }
                } label: {
                    sessionStatusPill(
                        succeeded: succeeded,
                        total: total,
                        remaining: remaining
                    )
                }
                .buttonStyle(.plain)
                .disabled(store.isCheckingIn)
            }

            if store.isCheckingIn {
                liveProgressCard
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let note = store.scannerOverlayNotification {
                floatingNotificationCard(note)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: store.isCheckingIn)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: store.scannerOverlayNotification?.id)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: succeeded)
        .task(id: store.scannerOverlayNotification?.id) {
            guard let note = store.scannerOverlayNotification else { return }
            triggerNotificationHaptic(for: note.kind)
            try? await Task.sleep(nanoseconds: 5_500_000_000)
            guard !Task.isCancelled else { return }
            if store.scannerOverlayNotification?.id == note.id {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    store.dismissScannerOverlayNotification()
                }
            }
        }
    }

    private func sessionStatusPill(succeeded: Int, total: Int, remaining: Int) -> some View {
        let allDone = remaining == 0
        let text: String
        if allDone {
            text = "本轮 \(total)/\(total) 全部成功 · 已暂停重复提交"
        } else if store.dryRun {
            text = "演练 · 本轮已签 \(succeeded)/\(total) · 剩余 \(remaining)"
        } else {
            text = "本轮已签 \(succeeded)/\(total) · 剩余 \(remaining)"
        }

        return HStack(spacing: 7) {
            if allDone {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.green)
            } else {
                Circle()
                    .fill(store.dryRun ? Color.blue : Color.green)
                    .frame(width: 7, height: 7)
            }

            Text(text)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(usesDarkChrome ? Color.white : LiquidPalette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.80)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            usesDarkChrome ? Color(white: 0.10, opacity: 0.86) : LiquidPalette.elevatedSurface(colorScheme),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .strokeBorder(
                    allDone
                        ? Color.green.opacity(usesDarkChrome ? 0.52 : 0.36)
                        : (usesDarkChrome ? Color.white.opacity(0.20) : LiquidPalette.hairline(colorScheme)),
                    lineWidth: 0.75
                )
                .allowsHitTesting(false)
        }
        .contentShape(Capsule())
        .shadow(color: Color.black.opacity(usesDarkChrome ? 0.32 : 0.08), radius: 8, x: 0, y: 3)
        .accessibilityLabel(text)
        .accessibilityHint("轻点查看本轮已成功账号名单与状态")
    }

    private var liveProgressCard: some View {
        let total = max(store.checkInTotalCount, 1)
        let progressText = store.dryRun
            ? "正在演练 \(store.checkInTotalCount) 个账号 (\(store.checkInCompletedCount)/\(total))"
            : "正在为 \(store.checkInTotalCount) 个账号签到 (\(store.checkInCompletedCount)/\(total))"

        return HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(usesDarkChrome ? Color.white : LiquidPalette.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(progressText)
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(usesDarkChrome ? Color.white : LiquidPalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)

                if store.activeBatchSkippedCount > 0 && !store.dryRun {
                    Text("已自动跳过本轮已成功的 \(store.activeBatchSkippedCount) 个账号")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(usesDarkChrome ? Color.white.opacity(0.72) : LiquidPalette.secondaryText)
                        .lineLimit(1)
                } else if !store.scannerSessionSucceededLabels.isEmpty && !store.dryRun {
                    let liveNames = store.scannerSessionSucceededLabels
                    let preview = liveNames.prefix(3).joined(separator: "、")
                    let suffix = liveNames.count > 3 ? " 等 \(liveNames.count) 个" : ""
                    Text("已成功：\(preview)\(suffix)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(usesDarkChrome ? Color.white.opacity(0.76) : LiquidPalette.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button {
                store.cancelCheckIn()
            } label: {
                Text("取消")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(usesDarkChrome ? Color.white : LiquidPalette.primaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(minWidth: 52, minHeight: 30)
                    .background(
                        usesDarkChrome ? Color.white.opacity(0.16) : LiquidPalette.subtleSurface(colorScheme),
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                usesDarkChrome ? Color.white.opacity(0.24) : LiquidPalette.hairline(colorScheme),
                                lineWidth: 0.75
                            )
                            .allowsHitTesting(false)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .accessibilityLabel("取消本次签到")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            usesDarkChrome ? Color(white: 0.10, opacity: 0.92) : LiquidPalette.elevatedSurface(colorScheme),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    usesDarkChrome ? Color.white.opacity(0.22) : LiquidPalette.hairline(colorScheme),
                    lineWidth: 0.85
                )
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(usesDarkChrome ? 0.42 : 0.14), radius: 14, x: 0, y: 6)
    }

    private func floatingNotificationCard(_ note: ScannerOverlayNotification) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: iconName(for: note.kind))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(accentColor(for: note.kind))
                    .padding(.top, 1)

                Text(note.title)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(usesDarkChrome ? Color.white : LiquidPalette.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        store.dismissScannerOverlayNotification()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(usesDarkChrome ? Color.white.opacity(0.84) : LiquidPalette.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            usesDarkChrome ? Color.white.opacity(0.14) : LiquidPalette.subtleSurface(colorScheme),
                            in: Circle()
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .accessibilityLabel("关闭扫码结果通知")
            }

            if !note.succeededLabels.isEmpty {
                succeededTagsSection(
                    title: note.kind == .info ? "已演练账号：" : "已成功账号：",
                    labels: note.succeededLabels,
                    isDryRunInfo: note.kind == .info
                )
            }

            if !note.failedSummaries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(note.failedSummaries.prefix(2).enumerated()), id: \.offset) { _, summary in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 5, height: 5)
                                .padding(.top, 5)

                            Text("待重试：\(summary)")
                                .font(.caption)
                                .foregroundStyle(
                                    usesDarkChrome ? Color.white.opacity(0.88) : LiquidPalette.primaryText
                                )
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if note.failedSummaries.count > 2 {
                        Text("+\(note.failedSummaries.count - 2) 个失败请在记录页查看")
                            .font(.caption2.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(
                                usesDarkChrome ? Color.white.opacity(0.68) : LiquidPalette.secondaryText
                            )
                            .padding(.leading, 11)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let detail = note.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(usesDarkChrome ? Color.white.opacity(0.74) : LiquidPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            usesDarkChrome ? Color(white: 0.10, opacity: 0.92) : LiquidPalette.elevatedSurface(colorScheme),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(borderColor(for: note.kind), lineWidth: 1.0)
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(usesDarkChrome ? 0.44 : 0.15), radius: 16, x: 0, y: 6)
    }

    private func succeededTagsSection(title: String, labels: [String], isDryRunInfo: Bool) -> some View {
        let maxDirectLabels = labels.count > 8 ? 7 : 8
        let visibleLabels = Array(labels.prefix(maxDirectLabels))
        let overflowCount = max(0, labels.count - visibleLabels.count)
        let tagColor: Color = isDryRunInfo
            ? (usesDarkChrome ? Color(red: 0.42, green: 0.74, blue: 1.0) : LiquidPalette.accent)
            : Color.green

        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(usesDarkChrome ? Color.white.opacity(0.84) : LiquidPalette.secondaryText)

            FlowTagLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(Array(visibleLabels.enumerated()), id: \.offset) { _, label in
                    HStack(spacing: 4) {
                        Image(systemName: isDryRunInfo ? "testtube.2" : "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(usesDarkChrome ? Color.white : tagColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        tagColor.opacity(usesDarkChrome ? 0.24 : 0.13),
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                tagColor.opacity(usesDarkChrome ? 0.50 : 0.30),
                                lineWidth: 0.75
                            )
                            .allowsHitTesting(false)
                    }
                }

                if overflowCount > 0 {
                    Text("+\(overflowCount) 个")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(
                            usesDarkChrome ? Color.white.opacity(0.88) : LiquidPalette.secondaryText
                        )
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            usesDarkChrome
                                ? Color.white.opacity(0.14)
                                : LiquidPalette.subtleSurface(colorScheme),
                            in: Capsule()
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func iconName(for kind: ScannerOverlayNotification.Kind) -> String {
        switch kind {
        case .success:
            return "checkmark.circle.fill"
        case .partial, .warning:
            return "exclamationmark.triangle.fill"
        case .failure:
            return "xmark.circle.fill"
        case .info:
            return "info.circle.fill"
        }
    }

    private func accentColor(for kind: ScannerOverlayNotification.Kind) -> Color {
        switch kind {
        case .success:
            return Color.green
        case .partial, .warning:
            return Color.orange
        case .failure:
            return Color.red
        case .info:
            return usesDarkChrome ? Color(red: 0.42, green: 0.74, blue: 1.0) : Color.blue
        }
    }

    private func borderColor(for kind: ScannerOverlayNotification.Kind) -> Color {
        switch kind {
        case .success:
            return Color.green.opacity(usesDarkChrome ? 0.52 : 0.38)
        case .partial, .warning:
            return Color.orange.opacity(usesDarkChrome ? 0.55 : 0.42)
        case .failure:
            return Color.red.opacity(usesDarkChrome ? 0.55 : 0.42)
        case .info:
            return Color.blue.opacity(usesDarkChrome ? 0.50 : 0.36)
        }
    }

    @MainActor
    private func triggerNotificationHaptic(for kind: ScannerOverlayNotification.Kind) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        switch kind {
        case .success:
            generator.notificationOccurred(.success)
        case .partial, .warning:
            generator.notificationOccurred(.warning)
        case .failure:
            generator.notificationOccurred(.error)
        case .info:
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.prepare()
            impact.impactOccurred()
        }
    }
}

/// Native iOS 16+ wrapping flow layout for account tag capsules inside the floating scanner notification.
private struct FlowTagLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    init(horizontalSpacing: CGFloat = 6, verticalSpacing: CGFloat = 6) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height: CGFloat
        if rows.isEmpty {
            height = 0
        } else {
            let rowsHeight = rows.reduce(CGFloat(0)) { $0 + $1.height }
            height = rowsHeight + CGFloat(rows.count - 1) * verticalSpacing
        }
        let resolvedWidth = maxWidth.isFinite ? min(maxWidth, width) : width
        return CGSize(width: resolvedWidth, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var currentY = bounds.minY
        for row in rows {
            var currentX = bounds.minX
            for item in row.items {
                let clampedWidth = min(item.size.width, bounds.width)
                let itemY = currentY + (row.height - item.size.height) / 2
                subviews[item.index].place(
                    at: CGPoint(x: currentX, y: itemY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: clampedWidth, height: item.size.height)
                )
                currentX += clampedWidth + horizontalSpacing
            }
            currentY += row.height + verticalSpacing
        }
    }

    private struct RowItem {
        let index: Int
        let size: CGSize
    }

    private struct Row {
        var items: [RowItem]
        var width: CGFloat
        var height: CGFloat
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        guard !subviews.isEmpty else { return [] }
        let effectiveMaxWidth = maxWidth.isFinite ? max(1, maxWidth) : CGFloat.infinity
        let childProposal = ProposedViewSize(
            width: effectiveMaxWidth.isFinite ? effectiveMaxWidth : nil,
            height: nil
        )

        var rows: [Row] = []
        var currentItems: [RowItem] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for index in subviews.indices {
            let measured = subviews[index].sizeThatFits(childProposal)
            let itemWidth = effectiveMaxWidth.isFinite ? min(measured.width, effectiveMaxWidth) : measured.width
            let itemSize = CGSize(width: itemWidth, height: measured.height)
            let neededWidth = currentItems.isEmpty ? itemSize.width : (currentWidth + horizontalSpacing + itemSize.width)

            if !currentItems.isEmpty && neededWidth > effectiveMaxWidth {
                rows.append(Row(items: currentItems, width: currentWidth, height: currentHeight))
                currentItems = [RowItem(index: index, size: itemSize)]
                currentWidth = itemSize.width
                currentHeight = itemSize.height
            } else {
                currentItems.append(RowItem(index: index, size: itemSize))
                currentWidth = neededWidth
                currentHeight = max(currentHeight, itemSize.height)
            }
        }

        if !currentItems.isEmpty {
            rows.append(Row(items: currentItems, width: currentWidth, height: currentHeight))
        }
        return rows
    }
}

/// 连续扫码存在性去重器：
/// - 镜头持续对准同一个二维码时保持静默（杜绝周期性重复震动、重复请求或重复历史）；
/// - 二维码内容变化（如动态码刷新）时零等待立即触发；
/// - 移开镜头超过 `absenceResetNanoseconds` 后再次对准同一码，且距上次触发超过 `minRetriggerNanoseconds` 时允许重扫一次。
struct ContinuousScanDeduplicator: Sendable {
    let absenceResetNanoseconds: UInt64
    let minRetriggerNanoseconds: UInt64

    private(set) var lastDeliveredCode: String?
    private(set) var lastDeliveredUptime: UInt64 = 0
    private(set) var lastSeenUptime: UInt64 = 0

    init(
        absenceResetNanoseconds: UInt64 = 1_200_000_000,
        minRetriggerNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.absenceResetNanoseconds = absenceResetNanoseconds
        self.minRetriggerNanoseconds = minRetriggerNanoseconds
    }

    mutating func reset() {
        lastDeliveredCode = nil
        lastDeliveredUptime = 0
        lastSeenUptime = 0
    }

    mutating func recordManualDelivery(_ code: String, now: UInt64) {
        lastDeliveredCode = code
        lastDeliveredUptime = now
        lastSeenUptime = now
    }

    mutating func shouldDeliverLiveScan(_ code: String, now: UInt64, isBusy: Bool) -> Bool {
        if isBusy {
            if lastDeliveredCode == code {
                lastSeenUptime = now
                lastDeliveredUptime = now
            }
            return false
        }

        if let lastCode = lastDeliveredCode, lastCode == code {
            let gapSinceLastSeen = now >= lastSeenUptime ? (now - lastSeenUptime) : 0
            let elapsedSinceDelivery = now >= lastDeliveredUptime ? (now - lastDeliveredUptime) : 0
            lastSeenUptime = now
            guard gapSinceLastSeen >= absenceResetNanoseconds,
                  elapsedSinceDelivery >= minRetriggerNanoseconds else {
                return false
            }
        }

        lastDeliveredCode = code
        lastDeliveredUptime = now
        lastSeenUptime = now
        return true
    }
}

/// Subtle disappearing monochrome square reticle for tap-to-focus feedback.
private struct FocusReticleView: View {
    let id: UUID

    @State private var scale: CGFloat = 1.24
    @State private var opacity: Double = 0.0

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(0.92), lineWidth: 1.5)
            .frame(width: 64, height: 64)
            .shadow(color: Color.black.opacity(0.32), radius: 4, x: 0, y: 1)
            .scaleEffect(scale)
            .opacity(opacity)
            .task(id: id) {
                scale = 1.24
                opacity = 0.0
                withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
                    scale = 1.0
                    opacity = 1.0
                }
                try? await Task.sleep(nanoseconds: 650_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.28)) {
                    opacity = 0.0
                }
            }
    }
}

@MainActor
private final class CameraScannerViewModel: ObservableObject {
    enum State: Equatable {
        case checking
        case authorized
        case denied
        case unavailable(String)
    }

    struct FocusIndicator: Equatable, Sendable {
        let id: UUID
        let point: CGPoint
    }

    @Published var state: State = .checking
    @Published var hasTorch = false
    @Published var isTorchOn = false
    @Published var orientationRevision = 0
    @Published var currentZoomFactor: CGFloat = 1.0
    @Published var minZoomFactor: CGFloat = 1.0
    @Published var maxZoomFactor: CGFloat = 1.0
    @Published var isPinchingZoom = false
    @Published var focusIndicator: FocusIndicator?
    @Published var isDecodingPhoto = false
    @Published var toastMessage: String?

    private var controller: CameraSessionController?
    private var isActive = false
    private var isContinuousMode = false
    private var didDeliverScan = false
    private var shouldIgnoreFrames: (@MainActor () -> Bool)?
    private var continuousDeduplicator = ContinuousScanDeduplicator()
    private var scanHandler: ((String) -> Void)?
    private var toastDismissTask: Task<Void, Never>?
    private var focusDismissTask: Task<Void, Never>?

    var session: AVCaptureSession {
        ensureController().session
    }

    var canZoom: Bool {
        maxZoomFactor > minZoomFactor + 0.05
    }

    var availableZoomPresets: [CGFloat] {
        guard canZoom else { return [] }
        let candidates: [CGFloat] = [1.0, 2.0, 3.0, 5.0]
        let filtered = candidates.filter { $0 >= minZoomFactor - 0.01 && $0 <= maxZoomFactor + 0.01 }
        return filtered.isEmpty ? [minZoomFactor] : filtered
    }

    var matchedZoomPreset: CGFloat? {
        availableZoomPresets.first { abs($0 - currentZoomFactor) < 0.08 }
    }

    var shouldShowLiveZoomBadge: Bool {
        canZoom && (isPinchingZoom || matchedZoomPreset == nil)
    }

    func start(
        continuousMode: Bool = false,
        shouldIgnoreFrames: (@MainActor () -> Bool)? = nil,
        onScanned: @escaping (String) -> Void
    ) {
        isContinuousMode = continuousMode
        self.shouldIgnoreFrames = shouldIgnoreFrames
        scanHandler = onScanned
        isActive = true
        didDeliverScan = false
        continuousDeduplicator.reset()

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            state = .authorized
            ensureController().start(continuousMode: continuousMode)

        case .notDetermined:
            state = .checking
            Task { @MainActor [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard let self, self.isActive else { return }
                if granted {
                    self.state = .authorized
                    self.ensureController().start(continuousMode: self.isContinuousMode)
                } else {
                    self.state = .denied
                }
            }

        case .denied, .restricted:
            state = .denied

        @unknown default:
            state = .denied
        }
    }

    func stop() {
        isActive = false
        didDeliverScan = false
        continuousDeduplicator.reset()
        shouldIgnoreFrames = nil
        scanHandler = nil
        toastDismissTask?.cancel()
        toastDismissTask = nil
        focusDismissTask?.cancel()
        focusDismissTask = nil
        controller?.stop()
        isTorchOn = false
        isPinchingZoom = false
        focusIndicator = nil
    }

    func toggleTorch() {
        controller?.toggleTorch()
    }

    func selectZoomPreset(_ factor: CGFloat) {
        guard canZoom else { return }
        let clamped = min(max(factor, minZoomFactor), maxZoomFactor)
        isPinchingZoom = false
        currentZoomFactor = clamped
        let feedback = UISelectionFeedbackGenerator()
        feedback.selectionChanged()
        controller?.rampZoom(to: clamped)
    }

    func beginPinchZoom() {
        guard canZoom else { return }
        isPinchingZoom = true
        controller?.beginPinchZoom()
    }

    func updatePinchZoom(scale: CGFloat) {
        guard canZoom, scale.isFinite, scale > 0 else { return }
        controller?.updatePinchZoom(scale: scale)
    }

    func endPinchZoom() {
        guard canZoom else { return }
        isPinchingZoom = false
        controller?.endPinchZoom()
    }

    func handleFocusTap(devicePoint: CGPoint, viewPoint: CGPoint) {
        controller?.focus(at: devicePoint)
        focusDismissTask?.cancel()
        let indicator = FocusIndicator(id: UUID(), point: viewPoint)
        focusIndicator = indicator
        focusDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.focusIndicator?.id == indicator.id {
                self.focusIndicator = nil
            }
        }
    }

    func deliverPhotoScan(_ code: String) {
        guard isActive else { return }
        if isContinuousMode {
            if shouldIgnoreFrames?() == true {
                showToast("正在签到中，请稍候完成后再试")
                return
            }
            continuousDeduplicator.recordManualDelivery(
                code,
                now: DispatchTime.now().uptimeNanoseconds
            )
            let feedback = UIImpactFeedbackGenerator(style: .light)
            feedback.prepare()
            feedback.impactOccurred()
            scanHandler?(code)
            return
        }

        guard !didDeliverScan else { return }
        didDeliverScan = true
        controller?.stop()
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.prepare()
        feedback.impactOccurred()
        scanHandler?(code)
    }

    private func handleLiveScannedCode(_ code: String) {
        guard isActive else { return }

        if isContinuousMode {
            let now = DispatchTime.now().uptimeNanoseconds
            let isBusy = shouldIgnoreFrames?() == true
            guard continuousDeduplicator.shouldDeliverLiveScan(code, now: now, isBusy: isBusy) else {
                return
            }

            let feedback = UIImpactFeedbackGenerator(style: .light)
            feedback.prepare()
            feedback.impactOccurred()
            scanHandler?(code)
            return
        }

        guard !didDeliverScan else { return }
        didDeliverScan = true
        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.success)
        scanHandler?(code)
    }

    func showToast(_ message: String) {
        toastDismissTask?.cancel()
        toastMessage = message
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.toastMessage = nil
        }
    }

    func clearToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        toastMessage = nil
    }

    private func ensureController() -> CameraSessionController {
        if let existing = controller {
            return existing
        }

        let created = CameraSessionController(
            onCodeScanned: { [weak self] code in
                Task { @MainActor in
                    self?.handleLiveScannedCode(code)
                }
            },
            onTorchStateChanged: { [weak self] available, active in
                Task { @MainActor in
                    guard let self else { return }
                    self.hasTorch = available
                    self.isTorchOn = active
                }
            },
            onZoomStateChanged: { [weak self] current, minFactor, maxFactor in
                Task { @MainActor in
                    guard let self else { return }
                    self.minZoomFactor = minFactor
                    self.maxZoomFactor = maxFactor
                    self.currentZoomFactor = current
                }
            },
            onSessionRunning: { [weak self] in
                Task { @MainActor in
                    guard let self, self.isActive else { return }
                    self.orientationRevision &+= 1
                }
            },
            onUnavailable: { [weak self] reason in
                Task { @MainActor in
                    guard let self, self.isActive else { return }
                    self.state = .unavailable(reason)
                }
            }
        )
        controller = created
        return created
    }
}

/// Isolates all AVCaptureSession configuration, torch, zoom, focus, and metadata callbacks on a private serial queue.
private final class CameraSessionController: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "cn.raincheck.camera.session", qos: .userInitiated)
    private let onCodeScanned: @Sendable (String) -> Void
    private let onTorchStateChanged: @Sendable (Bool, Bool) -> Void
    private let onZoomStateChanged: @Sendable (CGFloat, CGFloat, CGFloat) -> Void
    private let onSessionRunning: @Sendable () -> Void
    private let onUnavailable: @Sendable (String) -> Void

    private static let continuousQueueCoalesceNanoseconds: UInt64 = 150_000_000

    private var isConfigured = false
    private var isContinuousMode = false
    private var hasDeliveredScan = false
    private var lastForwardedCodeOnQueue: String?
    private var lastForwardedUptimeOnQueue: UInt64 = 0
    private var captureDevice: AVCaptureDevice?
    private var minZoomFactor: CGFloat = 1.0
    private var maxZoomFactor: CGFloat = 1.0
    private var pinchBaseZoomFactor: CGFloat = 1.0
    private var lastPublishedZoomFactor: CGFloat = 1.0

    init(
        onCodeScanned: @escaping @Sendable (String) -> Void,
        onTorchStateChanged: @escaping @Sendable (Bool, Bool) -> Void,
        onZoomStateChanged: @escaping @Sendable (CGFloat, CGFloat, CGFloat) -> Void,
        onSessionRunning: @escaping @Sendable () -> Void,
        onUnavailable: @escaping @Sendable (String) -> Void
    ) {
        self.onCodeScanned = onCodeScanned
        self.onTorchStateChanged = onTorchStateChanged
        self.onZoomStateChanged = onZoomStateChanged
        self.onSessionRunning = onSessionRunning
        self.onUnavailable = onUnavailable
        super.init()
    }

    func start(continuousMode: Bool = false) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.isContinuousMode = continuousMode
            self.hasDeliveredScan = false
            self.lastForwardedCodeOnQueue = nil
            self.lastForwardedUptimeOnQueue = 0

            if !self.isConfigured {
                guard self.configureSessionOnQueue() else { return }
            }

            self.applyDirectZoomOnQueue(self.minZoomFactor, forcePublish: true)

            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.onSessionRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.lastForwardedCodeOnQueue = nil
            self.lastForwardedUptimeOnQueue = 0
            self.cancelZoomRampOnQueue()
            self.setTorchOnQueue(enabled: false)
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice, device.hasTorch else { return }
            let nextEnabled = device.torchMode != .on
            self.setTorchOnQueue(enabled: nextEnabled)
        }
    }

    func beginPinchZoom() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isRampingVideoZoom {
                    device.cancelVideoZoomRamp()
                }
                self.pinchBaseZoomFactor = self.clampedZoomOnQueue(device.videoZoomFactor, for: device)
            } catch {
                self.pinchBaseZoomFactor = self.clampedZoomOnQueue(device.videoZoomFactor, for: device)
            }
            self.lastPublishedZoomFactor = self.pinchBaseZoomFactor
            self.onZoomStateChanged(self.pinchBaseZoomFactor, self.minZoomFactor, self.maxZoomFactor)
        }
    }

    func updatePinchZoom(scale: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, scale.isFinite, scale > 0 else { return }
            let target = self.pinchBaseZoomFactor * scale
            self.applyDirectZoomOnQueue(target, forcePublish: false)
        }
    }

    func endPinchZoom() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            let current = self.clampedZoomOnQueue(device.videoZoomFactor, for: device)
            self.lastPublishedZoomFactor = current
            self.onZoomStateChanged(current, self.minZoomFactor, self.maxZoomFactor)
        }
    }

    func rampZoom(to factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            let clamped = self.clampedZoomOnQueue(factor, for: device)

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isRampingVideoZoom {
                    device.cancelVideoZoomRamp()
                }
                if abs(device.videoZoomFactor - clamped) < 0.01 {
                    device.videoZoomFactor = clamped
                } else {
                    device.ramp(toVideoZoomFactor: clamped, withRate: 8.0)
                }
                self.lastPublishedZoomFactor = clamped
                self.onZoomStateChanged(clamped, self.minZoomFactor, self.maxZoomFactor)
            } catch {
                let current = self.clampedZoomOnQueue(device.videoZoomFactor, for: device)
                self.lastPublishedZoomFactor = current
                self.onZoomStateChanged(current, self.minZoomFactor, self.maxZoomFactor)
            }
        }
    }

    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            let clampedPoint = CGPoint(
                x: min(max(devicePoint.x, 0.0), 1.0),
                y: min(max(devicePoint.y, 0.0), 1.0)
            )

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = clampedPoint
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    } else if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }
                }

                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = clampedPoint
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    } else if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                }
            } catch {
                // Focus and exposure updates are best-effort and non-fatal.
            }
        }
    }

    private func configureSessionOnQueue() -> Bool {
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)

        guard let device else {
            onUnavailable("当前设备没有可用的后置摄像头，可从相册选择二维码图片或改用粘贴链接。")
            return false
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            onUnavailable("无法初始化相机输入，可从相册选择二维码图片或改用粘贴链接。")
            return false
        }

        session.beginConfiguration()

        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            onUnavailable("相机输入配置失败，可从相册选择二维码图片或改用粘贴链接。")
            return false
        }
        session.addInput(input)

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            session.commitConfiguration()
            onUnavailable("二维码识别输出不可用，可从相册选择二维码图片或改用粘贴链接。")
            return false
        }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: sessionQueue)

        guard metadataOutput.availableMetadataObjectTypes.contains(.qr) else {
            session.commitConfiguration()
            onUnavailable("当前相机不支持二维码识别，可从相册选择二维码图片或改用粘贴链接。")
            return false
        }
        metadataOutput.metadataObjectTypes = [.qr]

        session.commitConfiguration()

        captureDevice = device
        isConfigured = true
        refreshZoomBoundsOnQueue(for: device)
        onTorchStateChanged(device.hasTorch, false)
        return true
    }

    private func refreshZoomBoundsOnQueue(for device: AVCaptureDevice) {
        let lowerBound = max(1.0, device.minAvailableVideoZoomFactor)
        let formatUpper = min(device.activeFormat.videoMaxZoomFactor, device.maxAvailableVideoZoomFactor)
        let upperBound = min(max(formatUpper, lowerBound), 10.0)

        minZoomFactor = lowerBound
        maxZoomFactor = upperBound
        let current = clampedZoomOnQueue(device.videoZoomFactor, for: device)
        pinchBaseZoomFactor = current
        lastPublishedZoomFactor = current
        onZoomStateChanged(current, minZoomFactor, maxZoomFactor)
    }

    private func clampedZoomOnQueue(_ factor: CGFloat, for device: AVCaptureDevice) -> CGFloat {
        let safeMin = max(minZoomFactor, device.minAvailableVideoZoomFactor)
        let safeMax = max(safeMin, min(maxZoomFactor, device.maxAvailableVideoZoomFactor))
        return min(max(factor, safeMin), safeMax)
    }

    private func applyDirectZoomOnQueue(_ factor: CGFloat, forcePublish: Bool) {
        guard let device = captureDevice else { return }
        let clamped = clampedZoomOnQueue(factor, for: device)

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isRampingVideoZoom {
                device.cancelVideoZoomRamp()
            }
            device.videoZoomFactor = clamped

            if forcePublish || abs(clamped - lastPublishedZoomFactor) >= 0.01 {
                lastPublishedZoomFactor = clamped
                onZoomStateChanged(clamped, minZoomFactor, maxZoomFactor)
            }
        } catch {
            if forcePublish {
                let current = clampedZoomOnQueue(device.videoZoomFactor, for: device)
                lastPublishedZoomFactor = current
                onZoomStateChanged(current, minZoomFactor, maxZoomFactor)
            }
        }
    }

    private func cancelZoomRampOnQueue() {
        guard let device = captureDevice, device.isRampingVideoZoom else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.cancelVideoZoomRamp()
        } catch {
            // Non-fatal during shutdown.
        }
    }

    private func setTorchOnQueue(enabled: Bool) {
        guard let device = captureDevice, device.hasTorch else {
            onTorchStateChanged(false, false)
            return
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if enabled {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else {
                device.torchMode = .off
            }
            onTorchStateChanged(true, device.torchMode == .on)
        } catch {
            onTorchStateChanged(device.hasTorch, device.torchMode == .on)
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        if !isContinuousMode && hasDeliveredScan {
            return
        }

        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  readable.type == .qr,
                  let rawValue = readable.stringValue else {
                continue
            }

            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if isContinuousMode {
                let now = DispatchTime.now().uptimeNanoseconds
                if let lastCode = lastForwardedCodeOnQueue, lastCode == trimmed {
                    let elapsed = now >= lastForwardedUptimeOnQueue ? (now - lastForwardedUptimeOnQueue) : 0
                    if elapsed < Self.continuousQueueCoalesceNanoseconds {
                        return
                    }
                }
                lastForwardedCodeOnQueue = trimmed
                lastForwardedUptimeOnQueue = now
                onCodeScanned(trimmed)
                return
            }

            hasDeliveredScan = true
            cancelZoomRampOnQueue()
            setTorchOnQueue(enabled: false)
            if session.isRunning {
                session.stopRunning()
            }
            onCodeScanned(trimmed)
            return
        }
    }
}

@MainActor
private struct CameraPreviewRepresentable: UIViewRepresentable {
    let session: AVCaptureSession
    let orientationRevision: Int
    let onPinchBegan: () -> Void
    let onPinchChanged: (CGFloat) -> Void
    let onPinchEnded: () -> Void
    let onFocusTap: (CGPoint, CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPinchBegan: onPinchBegan,
            onPinchChanged: onPinchChanged,
            onPinchEnded: onPinchEnded,
            onFocusTap: onFocusTap
        )
    }

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.isUserInteractionEnabled = true
        view.previewLayer?.videoGravity = .resizeAspectFill
        view.previewLayer?.session = session
        view.updateVideoOrientation()

        let pinchGesture = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        view.addGestureRecognizer(pinchGesture)

        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tapGesture.numberOfTapsRequired = 1
        view.addGestureRecognizer(tapGesture)

        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        _ = orientationRevision
        context.coordinator.updateCallbacks(
            onPinchBegan: onPinchBegan,
            onPinchChanged: onPinchChanged,
            onPinchEnded: onPinchEnded,
            onFocusTap: onFocusTap
        )
        if uiView.previewLayer?.session !== session {
            uiView.previewLayer?.session = session
        }
        uiView.updateVideoOrientation()
    }

    static func dismantleUIView(_ uiView: CameraPreviewUIView, coordinator: Coordinator) {
        uiView.gestureRecognizers?.forEach { uiView.removeGestureRecognizer($0) }
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        private var onPinchBegan: () -> Void
        private var onPinchChanged: (CGFloat) -> Void
        private var onPinchEnded: () -> Void
        private var onFocusTap: (CGPoint, CGPoint) -> Void
        private var isDetached = false

        init(
            onPinchBegan: @escaping () -> Void,
            onPinchChanged: @escaping (CGFloat) -> Void,
            onPinchEnded: @escaping () -> Void,
            onFocusTap: @escaping (CGPoint, CGPoint) -> Void
        ) {
            self.onPinchBegan = onPinchBegan
            self.onPinchChanged = onPinchChanged
            self.onPinchEnded = onPinchEnded
            self.onFocusTap = onFocusTap
            super.init()
        }

        func updateCallbacks(
            onPinchBegan: @escaping () -> Void,
            onPinchChanged: @escaping (CGFloat) -> Void,
            onPinchEnded: @escaping () -> Void,
            onFocusTap: @escaping (CGPoint, CGPoint) -> Void
        ) {
            self.onPinchBegan = onPinchBegan
            self.onPinchChanged = onPinchChanged
            self.onPinchEnded = onPinchEnded
            self.onFocusTap = onFocusTap
        }

        func detach() {
            isDetached = true
        }

        @objc
        func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard !isDetached else { return }
            switch recognizer.state {
            case .began:
                onPinchBegan()
            case .changed:
                let scale = recognizer.scale
                if scale.isFinite && scale > 0 {
                    onPinchChanged(scale)
                }
            case .ended, .cancelled, .failed:
                onPinchEnded()
            default:
                break
            }
        }

        @objc
        func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard !isDetached,
                  recognizer.state == .ended,
                  let previewView = recognizer.view as? CameraPreviewUIView,
                  let previewLayer = previewView.previewLayer else {
                return
            }

            let viewPoint = recognizer.location(in: previewView)
            let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
            onFocusTap(devicePoint, viewPoint)
        }
    }
}

@MainActor
private final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer? {
        layer as? AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
        updateVideoOrientation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateVideoOrientation()
    }

    func updateVideoOrientation() {
        guard let connection = previewLayer?.connection,
              let interfaceOrientation = window?.windowScene?.interfaceOrientation else {
            return
        }

        if #available(iOS 17.0, *) {
            let angle: CGFloat
            switch interfaceOrientation {
            case .portrait:
                angle = 90
            case .landscapeRight:
                angle = 0
            case .portraitUpsideDown:
                angle = 270
            case .landscapeLeft:
                angle = 180
            default:
                angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else {
            let videoOrientation: AVCaptureVideoOrientation
            switch interfaceOrientation {
            case .portrait:
                videoOrientation = .portrait
            case .landscapeRight:
                videoOrientation = .landscapeRight
            case .portraitUpsideDown:
                videoOrientation = .portraitUpsideDown
            case .landscapeLeft:
                videoOrientation = .landscapeLeft
            default:
                videoOrientation = .portrait
            }
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = videoOrientation
            }
        }
    }
}
