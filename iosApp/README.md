# RainCheck iOS（雨课堂签到 · iOS 27 Liquid Glass）

极简原生 SwiftUI iOS 客户端，采用 Apple iOS 26 / iOS 27 原生 Liquid Glass 视觉语言，零第三方依赖，在 iOS 16–25 自动降级为克制的单色磨砂材质。

## 设计原则

- **单色基底 + 单一点缀色**：浅色背景纯中性 `#F5F5F7`、深色背景纯中性 `#0A0A0C`，全应用仅使用一套克制的冷蓝 `AccentColor`（浅色 `0.110 / 0.390 / 0.780`，深色 `0.360 / 0.620 / 0.960`）用于主操作与选中状态，严禁多色混搭、彩色渐变背景与彩虹标签。
- **原生 Liquid Glass**：在 `#if compiler(>=6.2)` 与 `#available(iOS 26.0, *)` 下直接调用 `GlassEffectContainer`、`.glassEffect(...)`、`.glassEffectID(_:in:)`、`.buttonStyle(.glass / .glassProminent)` 与 `.tabBarMinimizeBehavior(.onScrollDown)`，界面留白充足、不堆叠多余装饰。
- **纯系统框架与严格并发**：仅使用 `Foundation`、`SwiftUI`、`UIKit`、`WebKit`、`Security`、`AVFoundation`、`PhotosUI`、`Vision`、`CoreImage`、`CoreGraphics`、`ImageIO`，全面启用 `SWIFT_STRICT_CONCURRENCY: complete`。
- **账号接入与 Web 会话校验**：已移除微信二维码账号登录入口，专注手机号短信验证码登录（`PhoneLoginClient.swift` 对接官方 `/pc/login/send_sms_login_code/` 与 `/pc/login/verify_pwd_login/`，配合 `CaptchaSheet.swift` 腾讯防水墙交互式 `WKWebView` 验证）与手动凭据导入；网络层统一使用官方 Web 请求头（`X-Client: web`、`xtbz: ykt` 及同源 `Origin` / `Referer`，自动剥离旧 `desktop-v` 与 `Origin: file://`），并在短期课堂 `bearer` 过期时自动回退纯 Cookie 重试，同时兼容 Django 含 `expires=Tue, ... GMT` 日期逗号的多段 `Set-Cookie` 解析。
- **签到扫码增强**：`CameraScannerSheet.swift` 支持双指缩放、快捷倍率切换、点击对焦及系统相册选图，配合 `QrImageDecoder.swift`（`Vision` 优先 + `CoreImage` 兜底）解码相册中的签到二维码。
- **本地安全与脱敏导出**：账号凭据（Bearer / SessionID / CSRFToken）存入 Keychain（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`），元信息开启文件保护并排除备份；签到结果 `SignResult` 通过显式 `CodingKeys` 排除任何凭据字段。

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
│   ├── DesignSystem/                   # iOS 27 Liquid Glass 主题、基础控件、CameraScannerSheet（缩放/对焦/选图）、QrImageDecoder 与 CaptchaSheet
│   ├── Domain/                         # 领域模型、协议目录加载与二维码解析器
│   ├── Networking/                     # RainCheckClient（Web 请求头与会话重试）、CheckInOrchestrator 与 PhoneLoginClient
│   ├── Storage/                        # Keychain 安全存储与 @MainActor AppStore
│   └── Features/                       # 签到、账号管理、手机号验证码/手动导入表单与签到记录页面
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
