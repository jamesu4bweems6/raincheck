//
//  LiquidScannerSheet.swift
//  RainCheck
//
//  iOS 26 / 27 液态玻璃相机扫码页：
//   - 所有 AVCaptureSession 与 videoDevice 访问严格隔离在串行 sessionQueue，彻底消除线程竞态；
//   - 首次识别有效二维码立即 stopRunning() 并通过 MainActor 防抖守卫杜绝双回调与双关闭；
//   - 支持 iPad 与横竖屏自动旋转（iOS 17+ videoRotationAngle / iOS 16 videoOrientation）；
//   - 悬浮液态玻璃手电筒 / 粘贴 / 关闭控制组 + 折射角标取景框。
//

import SwiftUI
import AVFoundation
import UIKit

// MARK: - 串行采集工作器（无 MainActor 状态，完全隔离在 sessionQueue）

private final class CaptureSessionWorker: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "cn.raincheck.camera.session.serial")
    private var configured = false
    private var videoDevice: AVCaptureDevice?
    private var onCode: (@Sendable (String) -> Void)?
    private var onEvent: (@Sendable (WorkerEvent) -> Void)?

    enum WorkerEvent: Sendable {
        case running
        case failed(String)
        case torchAvailable(Bool)
        case torchChanged(Bool)
    }

    func setCallbacks(
        onCode: @escaping @Sendable (String) -> Void,
        onEvent: @escaping @Sendable (WorkerEvent) -> Void
    ) {
        sessionQueue.async { [weak self] in
            self?.onCode = onCode
            self?.onEvent = onEvent
        }
    }

    func prepareAndRun() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                self.configureSessionLocked()
            }
            guard self.configured else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.onEvent?(.running)
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.setTorchLocked(false)
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func setTorch(_ on: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let applied = self.setTorchLocked(on)
            self.onEvent?(.torchChanged(applied))
        }
    }

    private func configureSessionLocked() {
        session.beginConfiguration()
        session.sessionPreset = .high

        let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
        guard let camera,
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            session.commitConfiguration()
            onEvent?(.failed("当前设备没有可用的后置摄像头，可直接粘贴二维码文本。"))
            return
        }
        session.addInput(input)
        videoDevice = camera

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            onEvent?(.failed("无法初始化二维码元数据输出。"))
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: sessionQueue)
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()
        configured = true
        onEvent?(.torchAvailable(camera.hasTorch))
    }

    @discardableResult
    private func setTorchLocked(_ on: Bool) -> Bool {
        guard let device = videoDevice, device.hasTorch else {
            return false
        }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            return on
        } catch {
            return false
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        for object in metadataObjects {
            guard let codeObject = object as? AVMetadataMachineReadableCodeObject,
                  let rawValue = codeObject.stringValue?.trimmedNonEmpty else {
                continue
            }
            setTorchLocked(false)
            if session.isRunning {
                session.stopRunning()
            }
            onEvent?(.torchChanged(false))
            onCode?(rawValue)
            return
        }
    }
}

// MARK: - 相机扫码控制器（严格 @MainActor 隔离）

@MainActor
final class LiquidScannerController: ObservableObject {
    enum Status: Equatable, Sendable {
        case idle
        case requesting
        case denied
        case running
        case failed
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var errorText: String?
    @Published private(set) var torchAvailable: Bool = false
    @Published private(set) var torchOn: Bool = false

    private let worker = CaptureSessionWorker()
    private var hasDeliveredCode: Bool = false
    private var onCodeHandler: (@MainActor (String) -> Void)?

    var session: AVCaptureSession { worker.session }

    init() {
        worker.setCallbacks(
            onCode: { [weak self] payload in
                Task { @MainActor [weak self] in
                    guard let self, !self.hasDeliveredCode else { return }
                    self.hasDeliveredCode = true
                    self.torchOn = false
                    LiquidHaptics.notify(.success)
                    self.onCodeHandler?(payload)
                }
            },
            onEvent: { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch event {
                    case .running:
                        self.status = .running
                    case .failed(let text):
                        self.status = .failed
                        self.errorText = text
                    case .torchAvailable(let available):
                        self.torchAvailable = available
                    case .torchChanged(let on):
                        self.torchOn = on
                    }
                }
            }
        )
    }

    func bind(onCode: @escaping @MainActor (String) -> Void) {
        onCodeHandler = onCode
        hasDeliveredCode = false
    }

    func start() {
        hasDeliveredCode = false
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            worker.prepareAndRun()
        case .notDetermined:
            status = .requesting
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        self.worker.prepareAndRun()
                    } else {
                        self.status = .denied
                    }
                }
            }
        default:
            status = .denied
        }
    }

    func stop() {
        torchOn = false
        worker.stop()
    }

    func toggleTorch() {
        worker.setTorch(!torchOn)
    }
}

// MARK: - 相机预览层（支持横竖屏与 iPad 旋转）

final class LiquidCameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        (layer as? AVCaptureVideoPreviewLayer) ?? AVCaptureVideoPreviewLayer()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateOrientation()
    }

    func updateOrientation() {
        guard let connection = previewLayer.connection else { return }
        let orientation = window?.windowScene?.interfaceOrientation ?? .portrait
        if #available(iOS 17.0, *) {
            let angle: CGFloat
            switch orientation {
            case .portrait:
                angle = 90
            case .portraitUpsideDown:
                angle = 270
            case .landscapeLeft:
                angle = 180
            case .landscapeRight:
                angle = 0
            default:
                angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else {
            let videoOrientation: AVCaptureVideoOrientation
            switch orientation {
            case .portrait:
                videoOrientation = .portrait
            case .portraitUpsideDown:
                videoOrientation = .portraitUpsideDown
            case .landscapeLeft:
                videoOrientation = .landscapeLeft
            case .landscapeRight:
                videoOrientation = .landscapeRight
            default:
                videoOrientation = .portrait
            }
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = videoOrientation
            }
        }
    }
}

struct LiquidCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> LiquidCameraPreviewView {
        let view = LiquidCameraPreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: LiquidCameraPreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.updateOrientation()
    }
}

// MARK: - 液态玻璃扫码全屏页

struct LiquidScannerSheet: View {
    let onScanned: @MainActor (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var controller = LiquidScannerController()

    @State private var showingPasteSheet = false
    @State private var pasteDraft = ""
    @State private var didDismiss = false

    init(onScanned: @escaping @MainActor (String) -> Void) {
        self.onScanned = onScanned
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if controller.status == .running {
                LiquidCameraPreview(session: controller.session)
                    .ignoresSafeArea()
                viewfinderOverlay
            } else {
                LiquidAuroraCanvas(accent: LiquidPalette.cyan)
                statusPlaceholder
            }

            VStack(spacing: 0) {
                topFloatingBar
                Spacer()
                bottomHintBar
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .onAppear {
            didDismiss = false
            controller.bind { code in
                completeAndDismiss(with: code)
            }
            controller.start()
        }
        .onDisappear {
            controller.stop()
        }
        .sheet(isPresented: $showingPasteSheet) {
            pasteFallbackSheet
        }
    }

    private var topFloatingBar: some View {
        LiquidGlassGroup(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    closeWithoutResult()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .liquidGlass(.regular, tint: Color.black.opacity(0.25), interactive: true, in: Circle())
                .accessibilityLabel("关闭扫码")

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        showingPasteSheet = true
                    } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                    }
                    .liquidGlassCapsule(variant: .regular, tint: LiquidPalette.sapphire.opacity(0.35), interactive: true)

                    if controller.status == .running && controller.torchAvailable {
                        Button {
                            LiquidHaptics.impact(.light)
                            controller.toggleTorch()
                        } label: {
                            Image(systemName: controller.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(controller.torchOn ? LiquidPalette.amber : .white)
                                .frame(width: 44, height: 44)
                        }
                        .liquidGlass(
                            .regular,
                            tint: controller.torchOn ? LiquidPalette.amber : Color.black.opacity(0.25),
                            interactive: true,
                            in: Circle()
                        )
                        .accessibilityLabel(controller.torchOn ? "关闭手电筒" : "打开手电筒")
                    }
                }
            }
        }
    }

    private var viewfinderOverlay: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) * 0.68
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                // 柔和暗角框，突出取景窗口
                Rectangle()
                    .fill(Color.black.opacity(0.38))
                    .mask {
                        ZStack {
                            Rectangle()
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .frame(width: side, height: side)
                                .position(center)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }

                // 折射玻璃角标
                ScannerCornerFrame(cornerRadius: 28, armLength: 32)
                    .stroke(
                        LinearGradient(
                            colors: [LiquidPalette.cyan, .white, LiquidPalette.sapphire],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: side, height: side)
                    .position(center)
                    .shadow(color: LiquidPalette.cyan.opacity(0.55), radius: 10, x: 0, y: 0)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var bottomHintBar: some View {
        HStack(spacing: 8) {
            Image(systemName: controller.status == .running ? "viewfinder" : "doc.text.magnifyingglass")
                .foregroundStyle(LiquidPalette.cyan)
            Text(controller.status == .running
                 ? "对准课堂动态码或静态码，识别后安全预览不自动外发"
                 : "未开启相机时可直接粘贴二维码文本完成解析")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .liquidGlassCapsule(variant: .regular, tint: Color.black.opacity(0.35))
        .padding(.bottom, 12)
    }

    private var statusPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: placeholderIcon)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(LiquidPalette.sapphire)
                .padding(20)
                .liquidGlass(.regular, tint: LiquidPalette.sapphire, in: Circle())

            Text(statusTitle)
                .font(.title3.weight(.bold))

            if let error = controller.errorText {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if controller.status == .denied {
                Text("需要相机权限来读取课堂二维码；也可以在系统设置中重新开启，或直接粘贴二维码文本。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            LiquidGlassGroup(spacing: 12) {
                VStack(spacing: 10) {
                    if controller.status == .denied {
                        LiquidGlassActionButton(prominence: .prominent, tint: LiquidPalette.sapphire) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        } label: {
                            Label("前往系统设置开启相机", systemImage: "gearshape.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }

                    LiquidGlassActionButton(prominence: .glass, tint: LiquidPalette.cyan) {
                        showingPasteSheet = true
                    } label: {
                        Label("粘贴二维码文本", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxWidth: 280)
        }
        .padding(28)
        .liquidGlassCard(cornerRadius: 28, variant: .regular)
        .padding(.horizontal, 24)
    }

    private var pasteFallbackSheet: some View {
        NavigationStack {
            ZStack {
                LiquidAuroraCanvas(accent: LiquidPalette.cyan)
                VStack(alignment: .leading, spacing: 14) {
                    Text("粘贴完整 URL、`c=…&t=…&s=…` 裸参数或课堂号，确认后将返回签到台预览。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $pasteDraft)
                        .font(.system(.footnote, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .frame(minHeight: 170)
                        .liquidReadableSurface(cornerRadius: 18)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("粘贴二维码文本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingPasteSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使用") {
                        let cleaned = pasteDraft.trimmed
                        showingPasteSheet = false
                        if !cleaned.isEmpty {
                            completeAndDismiss(with: cleaned)
                        }
                    }
                    .disabled(pasteDraft.trimmed.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var placeholderIcon: String {
        switch controller.status {
        case .idle, .requesting: return "camera.aperture"
        case .denied: return "lock.shield"
        case .running: return "qrcode.viewfinder"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var statusTitle: String {
        switch controller.status {
        case .idle: return "相机初始化中"
        case .requesting: return "正在请求相机权限"
        case .denied: return "相机权限未开启"
        case .running: return "扫描中"
        case .failed: return "相机不可用"
        }
    }

    @MainActor
    private func completeAndDismiss(with code: String) {
        guard !didDismiss else { return }
        didDismiss = true
        controller.stop()
        onScanned(code)
        dismiss()
    }

    @MainActor
    private func closeWithoutResult() {
        guard !didDismiss else { return }
        didDismiss = true
        controller.stop()
        dismiss()
    }
}

/// 仅绘制四角折线的折射取景框形状。
private struct ScannerCornerFrame: Shape {
    let cornerRadius: CGFloat
    let armLength: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(cornerRadius, min(rect.width, rect.height) / 4)
        let arm = max(armLength, r + 6)

        // 左上角
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))

        // 右上角
        path.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + r),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))

        // 右下角
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))

        // 左下角
        path.move(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - arm))

        return path
    }
}
