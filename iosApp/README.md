# RainCheck iOS（雨课堂签到 · iOS 27 Liquid Glass）

极简原生 SwiftUI iOS 客户端，采用 Apple iOS 26 / iOS 27 原生 Liquid Glass 视觉语言，零第三方依赖，在 iOS 16–25 自动降级为克制的单色磨砂材质。

## 设计原则

- **单色基底 + 单一点缀色**：浅色背景纯中性 `#F5F5F7`、深色背景纯中性 `#0A0A0C`，全应用仅使用一套克制的冷蓝 `AccentColor`（浅色 `0.110 / 0.390 / 0.780`，深色 `0.360 / 0.620 / 0.960`）用于主操作与选中状态，严禁多色混搭、彩色渐变背景与彩虹标签。
- **原生 Liquid Glass**：在 `#if compiler(>=6.2)` 与 `#available(iOS 26.0, *)` 下直接调用 `GlassEffectContainer`、`.glassEffect(...)`、`.glassEffectID(_:in:)`、`.buttonStyle(.glass / .glassProminent)` 与 `.tabBarMinimizeBehavior(.onScrollDown)`，界面留白充足、不堆叠多余装饰。
- **纯系统框架与严格并发**：仅使用 `Foundation`、`SwiftUI`、`UIKit`、`WebKit`、`Security`、`AVFoundation`、`PhotosUI`、`Vision`、`CoreImage`、`CoreGraphics`、`ImageIO`，全面启用 `SWIFT_STRICT_CONCURRENCY: complete`。
- **账号接入与 Web 会话校验**：已移除微信二维码账号登录入口，专注手机号短信验证码登录（`PhoneLoginClient.swift` 对接官方 `/pc/login/send_sms_login_code/` 与 `/pc/login/verify_pwd_login/`，配合 `CaptchaSheet.swift` 腾讯防水墙交互式 `WKWebView` 验证）与手动凭据导入；网络层统一使用官方 Web 请求头（`X-Client: web`、`xtbz: ykt` 及同源 `Origin` / `Referer`，自动剥离旧 `desktop-v` 与 `Origin: file://`），并在短期课堂 `bearer` 过期时自动回退纯 Cookie 重试，同时兼容 Django 含 `expires=Tue, ... GMT` 日期逗号的多段 `Set-Cookie` 解析。
- **先选号、驻留连扫与会话级防重签（适配动态码）**：签到页采用「1. 多选签到账号 → 2. 扫码自动签到」流程；`CameraScannerSheet.swift` 支持双指缩放、快捷倍率切换、点击对焦与系统相册选图（`QrImageDecoder.swift` 以 `Vision` 优先、`CoreImage` 兜底）。实时扫码或相册识码后**保持驻留扫码界面不退出**，并通过 `ContinuousScanDeduplicator` 实现存在性智能去重（镜头持续对准同一二维码时静默不重复震动或重复提交，动态码刷新后零等待立即响应，移开镜头再对准可按需重扫）；签到期间与完成后在扫码界面顶部悬浮展示本轮进度、实时成功账号与自适应换行的成功账号胶囊名单（点击顶部状态胶囊可随时回看本轮进度与已禁用提交名单）。本轮已签到成功（`.success` / `.already`）的账号会自动在当前扫码会话内禁用重复提交（再次扫码直接跳过、零多余请求），并在下次重新进入扫码界面时自动重置（含会话 ID 隔离，防止快速关闭重开串扰），不修改账号池启用状态或勾选配置；同时对登录二维码、未知格式二维码与非受信任域名保持安全拦截，且不覆盖本轮已有成功批次的 `currentTicket`。
- **持久化扫码历史、完整日志与安全删除**：每次签到、演练完成（含中途取消时已完成的账号）后自动生成全字段脱敏的 `CheckInHistoryEntry`，由 `FileCheckInHistoryStore` 持久化至 `Application Support/RainCheck/checkin_history.json`（开启 `.completeFileProtection` 与 `isExcludedFromBackup`，最多保留最新 200 条；单元测试自动使用 `InMemoryCheckInHistoryStore` 隔离）。记录页（`RecordsView.swift`）提供「当前批次 / 历史记录」切换，重开应用后若有历史且当前批次为空则自动展示历史；支持展开查看完整时间、脱敏二维码/课堂/签到 ID 元数据、每账号诊断原因及完整 `AttemptTrace` 请求日志（策略、HTTP/业务码、URL、重定向终址与响应片段），并支持一键复制诊断、单条/全量脱敏 JSON 导出，以及带二次确认的单条删除、长按菜单与清空全部。
- **本地安全与脱敏导出**：账号凭据（Bearer / SessionID / CSRFToken）存入 Keychain（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`），元信息与历史记录开启文件保护并排除备份；签到结果 `SignResult` 通过显式 `CodingKeys` 排除任何凭据字段。

## 模块目录结构

```text
iosApp/
├── project.yml                         # XcodeGen 工程描述（RainCheck + RainCheckTests）
├── ExportOptions.plist                 # 可选自签名导出模板（默认 CI 不使用）
├── README.md
├── Resources/
│   ├── Info.plist                      # 相机权限、本地网络 ATS、屏幕方向与启动配置
│   ├── protocol_profile.json           # 与 ../protocol/profile.json 逐字节同步
│   └── Assets.xcassets/
│       ├── Contents.json
│       ├── AccentColor.colorset/       # 唯一冷蓝点缀色（Light / Dark）
│       └── AppIcon.appiconset/         # 3 套 1024x1024 无透明通道图标（AppIcon-Light / Dark / Tinted）
├── Sources/RainCheck/
│   ├── App/                            # 应用入口与 3 Tab 根视图（签到 / 账号 / 记录）
│   ├── DesignSystem/                   # iOS 27 Liquid Glass 主题、基础控件、CameraScannerSheet（连扫/悬浮通知/缩放/对焦/选图）、QrImageDecoder 与 CaptchaSheet
│   ├── Domain/                         # 领域模型（含 CheckInHistoryEntry / ScannerOverlayNotification）、协议目录加载与二维码解析器
│   ├── Networking/                     # RainCheckClient（Web 请求头与会话重试）、CheckInOrchestrator 与 PhoneLoginClient
│   ├── Storage/                        # Keychain 安全存储、持久化扫码历史（FileCheckInHistoryStore）与 @MainActor AppStore
│   └── Features/                       # 签到、账号管理、手机号验证码/手动导入表单与当前/历史签到记录页面
└── Tests/RainCheckTests/               # XCTest 单元测试（PhoneLoginClientTests、CheckInOrchestratorTests、QrCodeParserTests、QrImageDecoderTests 与 20 组跨端向量）
```

## 构建与测试（macOS / CI）

### 1. 生成 Xcode 工程

```bash
cd work/raincheck/iosApp
brew install xcodegen
xcodegen generate
```

### 2. 在 iOS Simulator 运行 XCTest

Apple Silicon 模拟器运行宿主测试需要本地零证书 Ad-Hoc 签名，使用独立 `build-sim` 目录以与未签名 Release 产物完全隔离：

```bash
xcodebuild test \
  -project RainCheck.xcodeproj \
  -scheme RainCheck \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath build-sim \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="-" \
  AD_HOC_CODE_SIGNING_ALLOWED=YES
```

### 3. 构建完全未签名的真机 Release `.app` 与 `.ipa`

```bash
xcodebuild build \
  -project RainCheck.xcodeproj \
  -scheme RainCheck \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""

rm -rf Payload RainCheck-unsigned.ipa
mkdir -p Payload
cp -R build/Build/Products/Release-iphoneos/RainCheck.app Payload/RainCheck.app
zip -qry RainCheck-unsigned.ipa Payload
```

未签名产物不应包含 `_CodeSignature` 目录或 `embedded.mobileprovision`。如需使用个人开发者证书签名导出，可参考 [ExportOptions.plist](ExportOptions.plist) 中的说明。

## 协议同步不变量与校验

- `iosApp/Resources/protocol_profile.json` 必须与仓库主协议 `protocol/profile.json` **逐字节一致（SHA-256 相同）**。
- `Resources/Info.plist` 仅开启 `NSAppTransportSecurity.NSAllowsLocalNetworking = true`，使本地演练环境 `http://127.0.0.1:8787` 可正常访问，同时保持公网域名默认 ATS HTTPS 保护。

在 `work/raincheck` 根目录执行以下校验（与 `.github/workflows/ios-unsigned.yml` 一致）：

```bash
cmp -s protocol/profile.json iosApp/Resources/protocol_profile.json
shasum -a 256 protocol/profile.json iosApp/Resources/protocol_profile.json
python3 tools/check_artifacts.py profile-sync --root .
python3 tools/check_artifacts.py ios-project --ios-dir iosApp
```
