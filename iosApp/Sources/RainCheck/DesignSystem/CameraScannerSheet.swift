import AVFoundation
import SwiftUI
import UIKit

/// Full-screen AVFoundation QR scanner with serial queue isolation, iPad orientation support, and Liquid Glass chrome.
struct CameraScannerSheet: View {
    let onScanned: (String) -> Void
    let onManualPaste: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var viewModel = CameraScannerViewModel()

    init(
        onScanned: @escaping (String) -> Void,
        onManualPaste: (() -> Void)? = nil
    ) {
        self.onScanned = onScanned
        self.onManualPaste = onManualPaste
    }

    var body: some View {
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
                    message: "请在系统设置中允许访问相机以扫描签到二维码，或改用粘贴链接。",
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
        .onAppear {
            viewModel.start { code in
                onScanned(code)
                dismiss()
            }
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private var liveScannerContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewRepresentable(
                session: viewModel.session,
                orientationRevision: viewModel.orientationRevision
            )
            .ignoresSafeArea()

            viewfinderFrame
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                LiquidGlassGroup(spacing: 12) {
                    HStack {
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

                LiquidGlassGroup(spacing: 12) {
                    VStack(spacing: 12) {
                        Text("将雨课堂签到二维码置于框内")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .liquidGlassCapsule(interactive: false)

                        if let onManualPaste {
                            Button {
                                dismiss()
                                onManualPaste()
                            } label: {
                                Label("粘贴链接", systemImage: "doc.on.clipboard")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            .liquidGlassCapsule(interactive: true)
                        }
                    }
                }
                .padding(.bottom, 34)
            }
            .environment(\.colorScheme, .dark)
        }
    }

    private var viewfinderFrame: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(Color.white.opacity(0.72), lineWidth: 1.5)
            .frame(width: 248, height: 248)
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
                                    .frame(maxWidth: .infinity)
                            }
                            .liquidPrimaryButtonStyle()
                        }

                        if let onManualPaste {
                            if showSettingsButton {
                                Button {
                                    dismiss()
                                    onManualPaste()
                                } label: {
                                    Text("改为粘贴链接")
                                        .frame(maxWidth: .infinity)
                                }
                                .liquidSecondaryButtonStyle()
                            } else {
                                Button {
                                    dismiss()
                                    onManualPaste()
                                } label: {
                                    Text("改为粘贴链接")
                                        .frame(maxWidth: .infinity)
                                }
                                .liquidPrimaryButtonStyle()
                            }
                        }
                    }
                }
                .frame(maxWidth: 260)

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
}

@MainActor
private final class CameraScannerViewModel: ObservableObject {
    enum State: Equatable {
        case checking
        case authorized
        case denied
        case unavailable(String)
    }

    @Published var state: State = .checking
    @Published var hasTorch = false
    @Published var isTorchOn = false
    @Published var orientationRevision = 0

    private var controller: CameraSessionController?
    private var isActive = false
    private var didDeliverScan = false
    private var scanHandler: ((String) -> Void)?

    var session: AVCaptureSession {
        ensureController().session
    }

    func start(onScanned: @escaping (String) -> Void) {
        scanHandler = onScanned
        isActive = true
        didDeliverScan = false

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            state = .authorized
            ensureController().start()

        case .notDetermined:
            state = .checking
            Task { @MainActor [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard let self, self.isActive else { return }
                if granted {
                    self.state = .authorized
                    self.ensureController().start()
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
        controller?.stop()
        isTorchOn = false
    }

    func toggleTorch() {
        controller?.toggleTorch()
    }

    private func ensureController() -> CameraSessionController {
        if let existing = controller {
            return existing
        }

        let created = CameraSessionController(
            onCodeScanned: { [weak self] code in
                Task { @MainActor in
                    guard let self, self.isActive, !self.didDeliverScan else { return }
                    self.didDeliverScan = true
                    let feedback = UINotificationFeedbackGenerator()
                    feedback.notificationOccurred(.success)
                    self.scanHandler?(code)
                }
            },
            onTorchStateChanged: { [weak self] available, active in
                Task { @MainActor in
                    guard let self else { return }
                    self.hasTorch = available
                    self.isTorchOn = active
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

/// Isolates all AVCaptureSession configuration, torch control, and metadata callbacks on a private serial queue.
private final class CameraSessionController: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "cn.raincheck.camera.session", qos: .userInitiated)
    private let onCodeScanned: @Sendable (String) -> Void
    private let onTorchStateChanged: @Sendable (Bool, Bool) -> Void
    private let onSessionRunning: @Sendable () -> Void
    private let onUnavailable: @Sendable (String) -> Void

    private var isConfigured = false
    private var hasDeliveredScan = false
    private var captureDevice: AVCaptureDevice?

    init(
        onCodeScanned: @escaping @Sendable (String) -> Void,
        onTorchStateChanged: @escaping @Sendable (Bool, Bool) -> Void,
        onSessionRunning: @escaping @Sendable () -> Void,
        onUnavailable: @escaping @Sendable (String) -> Void
    ) {
        self.onCodeScanned = onCodeScanned
        self.onTorchStateChanged = onTorchStateChanged
        self.onSessionRunning = onSessionRunning
        self.onUnavailable = onUnavailable
        super.init()
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.hasDeliveredScan = false

            if !self.isConfigured {
                guard self.configureSessionOnQueue() else { return }
            }

            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.onSessionRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
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

    private func configureSessionOnQueue() -> Bool {
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)

        guard let device else {
            onUnavailable("当前设备没有可用的后置摄像头，请改用粘贴链接。")
            return false
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            onUnavailable("无法初始化相机输入，请重试或改用粘贴链接。")
            return false
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        guard session.canAddInput(input) else {
            onUnavailable("相机输入配置失败，请改用粘贴链接。")
            return false
        }
        session.addInput(input)

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            onUnavailable("二维码识别输出不可用，请改用粘贴链接。")
            return false
        }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: sessionQueue)

        guard metadataOutput.availableMetadataObjectTypes.contains(.qr) else {
            onUnavailable("当前相机不支持二维码识别，请改用粘贴链接。")
            return false
        }
        metadataOutput.metadataObjectTypes = [.qr]

        captureDevice = device
        isConfigured = true
        onTorchStateChanged(device.hasTorch, false)
        return true
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
        guard !hasDeliveredScan else { return }

        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  readable.type == .qr,
                  let rawValue = readable.stringValue else {
                continue
            }

            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            hasDeliveredScan = true
            setTorchOnQueue(enabled: false)
            if session.isRunning {
                session.stopRunning()
            }
            onCodeScanned(trimmed)
            return
        }
    }
}

private struct CameraPreviewRepresentable: UIViewRepresentable {
    let session: AVCaptureSession
    let orientationRevision: Int

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer?.videoGravity = .resizeAspectFill
        view.previewLayer?.session = session
        view.updateVideoOrientation()
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        _ = orientationRevision
        if uiView.previewLayer?.session !== session {
            uiView.previewLayer?.session = session
        }
        uiView.updateVideoOrientation()
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
