import Foundation
import SwiftUI
import WebKit

/// 面向手机短信登录的交互式人机安全验证弹窗（腾讯防水墙 TCaptcha + 雨课堂备用 hCaptcha）。
struct CaptchaSheet: View {
    let edition: Edition
    let onCompleted: (CaptchaToken) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var mode: CaptchaMode = .tencent
    @State private var loadState: CaptchaLoadState = .loading
    @State private var reloadToken = UUID()
    @State private var didFinish = false

    init(
        edition: Edition,
        onCompleted: @escaping (CaptchaToken) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.edition = edition
        self.onCompleted = onCompleted
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidCanvas()

                VStack(spacing: 0) {
                    if mode == .hcaptchaFallback && loadState == .ready {
                        fallbackBanner
                    }

                    ZStack {
                        CaptchaWebView(
                            edition: edition,
                            mode: mode,
                            reloadToken: reloadToken,
                            onCompleted: { token in
                                finishWithToken(token)
                            },
                            onCancel: {
                                finishWithCancel()
                            },
                            onStateChange: { nextState in
                                loadState = nextState
                            }
                        )
                        .opacity(loadState.isFailed ? 0 : 1)

                        switch loadState {
                        case .loading:
                            loadingCard
                                .allowsHitTesting(false)

                        case .ready:
                            EmptyView()

                        case .failed(let message):
                            errorCard(message: message)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("安全验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") {
                        finishWithCancel()
                    }
                    .foregroundStyle(LiquidPalette.primaryText)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .onDisappear {
            if !didFinish {
                didFinish = true
                onCancel()
            }
        }
    }

    private var fallbackBanner: some View {
        HStack(spacing: 12) {
            Text("完成验证后将自动发送短信验证码")
                .font(.footnote)
                .foregroundStyle(LiquidPalette.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button("切回默认验证") {
                switchMode(to: .tencent)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(LiquidPalette.accent)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
        .padding(.vertical, 10)
    }

    private var loadingCard: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(LiquidPalette.accent)
            Text(mode == .tencent ? "正在加载安全验证…" : "正在加载备用验证…")
                .font(.subheadline)
                .foregroundStyle(LiquidPalette.secondaryText)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .liquidGlassCard()
    }

    private func errorCard(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.slash")
                .font(.title2)
                .foregroundStyle(LiquidPalette.secondaryText)

            Text("安全验证暂不可用")
                .font(.headline.weight(.semibold))
                .foregroundStyle(LiquidPalette.primaryText)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(LiquidPalette.secondaryText)
                .multilineTextAlignment(.center)

            LiquidGlassGroup(spacing: 10) {
                VStack(spacing: 10) {
                    Button {
                        retryCurrentMode()
                    } label: {
                        Text("重新加载")
                            .frame(maxWidth: .infinity)
                    }
                    .liquidPrimaryButtonStyle()

                    if mode == .tencent {
                        Button {
                            switchMode(to: .hcaptchaFallback)
                        } label: {
                            Text("使用备用验证")
                                .frame(maxWidth: .infinity)
                        }
                        .liquidSecondaryButtonStyle()
                    } else {
                        Button {
                            switchMode(to: .tencent)
                        } label: {
                            Text("切回腾讯安全验证")
                                .frame(maxWidth: .infinity)
                        }
                        .liquidSecondaryButtonStyle()
                    }
                }
            }
            .frame(maxWidth: 240)
        }
        .padding(LiquidMetrics.cardPadding)
        .frame(maxWidth: 320)
        .liquidGlassCard()
        .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
    }

    private func retryCurrentMode() {
        loadState = .loading
        reloadToken = UUID()
    }

    private func switchMode(to nextMode: CaptchaMode) {
        mode = nextMode
        loadState = .loading
        reloadToken = UUID()
    }

    private func finishWithToken(_ token: CaptchaToken) {
        guard !didFinish else { return }
        didFinish = true
        onCompleted(token)
        dismiss()
    }

    private func finishWithCancel() {
        guard !didFinish else { return }
        didFinish = true
        onCancel()
        dismiss()
    }
}

private enum CaptchaMode: String, Equatable {
    case tencent
    case hcaptchaFallback
}

private enum CaptchaLoadState: Equatable {
    case loading
    case ready
    case failed(String)

    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

@MainActor
private protocol CaptchaScriptMessageDelegate: AnyObject {
    func captchaDidReceiveScriptMessage(_ message: WKScriptMessage)
}

/// 弱引用代理，避免 `WKUserContentController` 强持有 Coordinator 造成循环引用。
@MainActor
private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var delegate: (any CaptchaScriptMessageDelegate)?

    init(delegate: any CaptchaScriptMessageDelegate) {
        self.delegate = delegate
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.captchaDidReceiveScriptMessage(message)
    }
}

@MainActor
private struct CaptchaWebView: UIViewRepresentable {
    static let messageHandlerName = "raincheckCaptcha"

    let edition: Edition
    let mode: CaptchaMode
    let reloadToken: UUID
    let onCompleted: (CaptchaToken) -> Void
    let onCancel: () -> Void
    let onStateChange: (CaptchaLoadState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onCompleted: onCompleted,
            onCancel: onCancel,
            onStateChange: onStateChange
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()

        let userContentController = WKUserContentController()
        let proxy = WeakScriptMessageProxy(delegate: context.coordinator)
        userContentController.add(proxy, name: Self.messageHandlerName)
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        context.coordinator.loadIfNeeded(
            in: webView,
            edition: edition,
            mode: mode,
            reloadToken: reloadToken
        )
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.updateCallbacks(
            onCompleted: onCompleted,
            onCancel: onCancel,
            onStateChange: onStateChange
        )
        context.coordinator.loadIfNeeded(
            in: uiView,
            edition: edition,
            mode: mode,
            reloadToken: reloadToken
        )
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
        uiView.configuration.userContentController.removeAllUserScripts()
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, CaptchaScriptMessageDelegate {
        private var onCompleted: (CaptchaToken) -> Void
        private var onCancel: () -> Void
        private var onStateChange: (CaptchaLoadState) -> Void
        private var lastLoadedKey: String?
        private var activeMode: CaptchaMode = .tencent
        private var isDetached = false
        private var didDeliverResult = false

        init(
            onCompleted: @escaping (CaptchaToken) -> Void,
            onCancel: @escaping () -> Void,
            onStateChange: @escaping (CaptchaLoadState) -> Void
        ) {
            self.onCompleted = onCompleted
            self.onCancel = onCancel
            self.onStateChange = onStateChange
            super.init()
        }

        func updateCallbacks(
            onCompleted: @escaping (CaptchaToken) -> Void,
            onCancel: @escaping () -> Void,
            onStateChange: @escaping (CaptchaLoadState) -> Void
        ) {
            self.onCompleted = onCompleted
            self.onCancel = onCancel
            self.onStateChange = onStateChange
        }

        func detach() {
            isDetached = true
        }

        func loadIfNeeded(
            in webView: WKWebView,
            edition: Edition,
            mode: CaptchaMode,
            reloadToken: UUID
        ) {
            let loadKey = "\(edition.id)|\(mode.rawValue)|\(reloadToken.uuidString)"
            guard loadKey != lastLoadedKey else { return }

            lastLoadedKey = loadKey
            activeMode = mode
            didDeliverResult = false

            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            webView.stopLoading()

            switch mode {
            case .tencent:
                let html = Self.tencentCaptchaHTML(appId: PhoneLoginClient.tencentCaptchaAppId)
                let baseURL = URL(string: "\(edition.scheme)://\(edition.host)/web")
                webView.loadHTMLString(html, baseURL: baseURL)

            case .hcaptchaFallback:
                let fallbackScript = WKUserScript(
                    source: Self.hcaptchaObserverScript,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
                controller.addUserScript(fallbackScript)

                let targetScheme = edition.scheme.lowercased() == "http" ? "http" : "https"
                guard let url = URL(string: "\(targetScheme)://\(edition.host)/authorize/hcaptcha_app?lang=zh-cn") else {
                    Task { @MainActor [weak self] in
                        guard let self, !self.isDetached else { return }
                        self.onStateChange(.failed("备用验证地址无效，请重试"))
                    }
                    return
                }
                var request = URLRequest(url: url)
                request.timeoutInterval = 25
                webView.load(request)
            }
        }

        func captchaDidReceiveScriptMessage(_ message: WKScriptMessage) {
            guard !isDetached,
                  message.name == CaptchaWebView.messageHandlerName,
                  let payload = message.body as? [String: Any],
                  let event = payload["event"] as? String else {
                return
            }

            let ticket = (payload["ticket"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let randstr = (payload["randstr"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hcaptchaToken = (payload["hcaptchaToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = (payload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            switch event {
            case "ready":
                onStateChange(.ready)

            case "success":
                guard !didDeliverResult else { return }
                guard !ticket.isEmpty || !hcaptchaToken.isEmpty else {
                    onStateChange(.failed("未获取到有效的验证凭据，请重试"))
                    return
                }
                didDeliverResult = true
                let token = CaptchaToken(
                    ticket: ticket,
                    randstr: randstr,
                    hcaptchaToken: hcaptchaToken
                )
                onCompleted(token)

            case "cancel":
                guard !didDeliverResult else { return }
                didDeliverResult = true
                onCancel()

            case "error":
                let messageText = detail.isEmpty ? "安全验证加载失败，请重试" : detail
                onStateChange(.failed(messageText))

            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !isDetached else { return }
            if activeMode == .hcaptchaFallback {
                onStateChange(.ready)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleNavigationError(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleNavigationError(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard !isDetached, !didDeliverResult else { return }
            onStateChange(.failed("验证页面进程已中断，请重新加载"))
        }

        private func handleNavigationError(_ error: Error) {
            guard !isDetached, !didDeliverResult else { return }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }
            if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
                return
            }
            onStateChange(.failed("网络异常，无法加载安全验证（\(nsError.localizedDescription)）"))
        }

        private static func tencentCaptchaHTML(appId: String) -> String {
            let safeAppId = appId.filter { $0.isASCII && ($0.isNumber || $0.isLetter) }
            return """
            <!DOCTYPE html>
            <html lang="zh-CN">
            <head>
              <meta charset="utf-8" />
              <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
              <style>
                * {
                  -webkit-user-select: none;
                  box-sizing: border-box;
                }
                html, body {
                  width: 100%;
                  height: 100%;
                  margin: 0;
                  padding: 0;
                  background: transparent;
                  overflow: hidden;
                }
              </style>
              <script>
                (function () {
                  var finished = false;
                  var readySent = false;
                  var watchdog = null;

                  function post(payload) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.raincheckCaptcha) {
                      window.webkit.messageHandlers.raincheckCaptcha.postMessage(payload);
                    }
                  }

                  function clearWatchdog() {
                    if (watchdog !== null) {
                      clearTimeout(watchdog);
                      watchdog = null;
                    }
                  }

                  function notifyReady() {
                    if (readySent || finished) { return; }
                    readySent = true;
                    clearWatchdog();
                    post({
                      event: 'ready',
                      ticket: '',
                      randstr: '',
                      hcaptchaToken: '',
                      message: ''
                    });
                  }

                  window.__raincheckScriptError = function (msg) {
                    if (finished) { return; }
                    clearWatchdog();
                    post({
                      event: 'error',
                      ticket: '',
                      randstr: '',
                      hcaptchaToken: '',
                      message: msg || '安全验证脚本加载失败，请重试或切换备用验证'
                    });
                  };

                  window.__raincheckStartCaptcha = function () {
                    if (finished) { return; }
                    if (typeof window.TencentCaptcha !== 'function') {
                      window.__raincheckScriptError('未能加载腾讯安全验证组件，请重试或切换备用验证');
                      return;
                    }
                    try {
                      var captcha = new window.TencentCaptcha('\(safeAppId)', function (res) {
                        if (finished) { return; }
                        clearWatchdog();
                        if (res && res.ret === 0 && res.ticket) {
                          finished = true;
                          post({
                            event: 'success',
                            ticket: String(res.ticket || ''),
                            randstr: String(res.randstr || ''),
                            hcaptchaToken: '',
                            message: ''
                          });
                        } else if (res && res.ret === 2) {
                          finished = true;
                          post({
                            event: 'cancel',
                            ticket: '',
                            randstr: '',
                            hcaptchaToken: '',
                            message: ''
                          });
                        } else {
                          var detail = (res && (res.errorMessage || res.msg))
                            ? String(res.errorMessage || res.msg)
                            : '安全验证未通过，请重试';
                          post({
                            event: 'error',
                            ticket: '',
                            randstr: '',
                            hcaptchaToken: '',
                            message: detail
                          });
                        }
                      }, {
                        ready: function () {
                          notifyReady();
                        }
                      });
                      captcha.show();
                      setTimeout(function () {
                        notifyReady();
                      }, 1200);
                    } catch (err) {
                      window.__raincheckScriptError('安全验证初始化失败，请重试或切换备用验证');
                    }
                  };

                  watchdog = setTimeout(function () {
                    if (!readySent && !finished) {
                      window.__raincheckScriptError('安全验证加载超时，请重试或切换备用验证');
                    }
                  }, 15000);
                })();
              </script>
              <script src="https://turing.captcha.qcloud.com/TCaptcha.js" async onload="window.__raincheckStartCaptcha()" onerror="window.__raincheckScriptError('安全验证脚本加载失败，请重试或切换备用验证')"></script>
            </head>
            <body></body>
            </html>
            """
        }

        private static let hcaptchaObserverScript = """
        (function () {
          var delivered = false;
          function postToken(token) {
            if (delivered || !token) { return; }
            delivered = true;
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.raincheckCaptcha) {
              window.webkit.messageHandlers.raincheckCaptcha.postMessage({
                event: 'success',
                ticket: '',
                randstr: '',
                hcaptchaToken: String(token),
                message: ''
              });
            }
          }
          function readToken() {
            try {
              if (window.hcaptcha && typeof window.hcaptcha.getResponse === 'function') {
                var direct = window.hcaptcha.getResponse();
                if (direct && String(direct).trim().length > 0) {
                  return String(direct).trim();
                }
              }
            } catch (e) {}
            var field = document.querySelector('textarea[name="h-captcha-response"], input[name="h-captcha-response"]');
            if (field && field.value && String(field.value).trim().length > 0) {
              return String(field.value).trim();
            }
            return '';
          }
          var timer = setInterval(function () {
            if (delivered) {
              clearInterval(timer);
              return;
            }
            var token = readToken();
            if (token) {
              clearInterval(timer);
              postToken(token);
            }
          }, 350);
          window.addEventListener('pagehide', function () {
            clearInterval(timer);
          });
        })();
        """
    }
}
