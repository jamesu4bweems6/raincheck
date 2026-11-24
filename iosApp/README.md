# RainCheck iOS（iOS 26 / 27 Liquid Glass · SwiftUI + AVFoundation + Keychain）

雨课堂多账号扫码签到的 iOS 端原生 SwiftUI 客户端。协议路径、请求体与策略顺序全部由内置的
`Resources/protocol_profile.json` 驱动（逐字节同步自 `protocol/profile.json`），行为与 Kotlin
`core`（`core/src/commonMain/kotlin/cn/raincheck/core/`）保持 100% 跨端一致。

- **视觉体系**：原生 Apple **iOS 26 / 27 Liquid Glass（液态玻璃）**，通过 `#if compiler(>=6.2)` +
  `if #available(iOS 26.0, *)` 封装 `GlassEffectContainer`、`.glassEffect`、`.glassEffectID`、
  `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)` 与 `.tabBarMinimizeBehavior(.onScrollDown)`；
  在 iOS 16–25 / 旧版 SDK 下自动降级为流体极光 + 多层材质 + 方向性镜面高光描边渲染
- **纯系统框架**：`Foundation` / `SwiftUI` / `UIKit` / `Security` / `AVFoundation` / `CoreImage` / `CoreGraphics`（零第三方依赖）
- **凭据安全**：敏感凭据（`bearer` / `sessionId` / `csrfToken`）存入 iOS **Keychain**
  （`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）；非敏感元信息落盘启用 `.completeFileProtection`
  并设置 `isExcludedFromBackup = true`（不随 iCloud 备份）；导出排障 JSON 永久排除凭据字段
- **网络安全**：`Info.plist` 仅启用 `NSAppTransportSecurity.NSAllowsLocalNetworking = true`（保障内置
  `mock` `http://127.0.0.1:8787` 畅通，公网保持默认 ATS HTTPS 保护）；`QR_URL_POST`/`QR_URL_GET`
  强制执行同源/白名单域名与协议校验，且默认关闭扫码零点击自动签到
- **未签名构建**：`CODE_SIGNING_ALLOWED=NO`，含真实 XCTest 单元测试靶标 `RainCheckTests`

---

## 1. 在 macOS 上测试与构建

本仓库当前工作机为 Windows，无法在本地直接运行 Apple `xcodebuild` / iOS SDK；完整单测与未签名
`.ipa` 打包由 `.github/workflows/ios-unsigned.yml` 在 **`macos-26`** runner（Xcode 26/27）上执行。

本地 macOS 复现命令：

```bash
# 1) 安装 XcodeGen（只需一次）
brew install xcodegen
xcodebuild -version

# 2) 进入 iOS 工程目录
cd work/raincheck/iosApp

# 3) 校验协议文件与仓库真源完全一致
cmp -s ../protocol/profile.json Resources/protocol_profile.json

# 4) 生成 Xcode 工程
xcodegen generate

# 5) 在 iOS Simulator 上运行 RainCheckTests（含全部 20 条 qr_cases.json 跨端向量）
#    注：Apple Silicon arm64 Simulator 运行宿主 App 测试需零证书本地 Ad-Hoc 签名（"-"），
#    独立使用 build-sim 目录，不影响下方真机 Release 完全未签名构建。
xcodebuild \
  -project RainCheck.xcodeproj \
  -scheme RainCheck \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath build-sim \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="-" \
  AD_HOC_CODE_SIGNING_ALLOWED=YES \
  test

# 6) 构建未签名真机 .app（arm64，严格无证书、无 _CodeSignature）
xcodebuild \
  -project RainCheck.xcodeproj \
  -scheme RainCheck \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build
```

打包未签名 `.ipa`：

```bash
APP="build/Build/Products/Release-iphoneos/RainCheck.app"
rm -rf Payload RainCheck-unsigned.ipa
mkdir -p Payload
cp -R "$APP" Payload/RainCheck.app
rm -rf Payload/RainCheck.app/_CodeSignature
zip -qry RainCheck-unsigned.ipa Payload
```

> 真机安装需使用个人 Apple ID 或开发者证书自签（Xcode 直连 / AltStore / SideStore / 自备证书配合
> `ExportOptions.plist`）。本仓库不内置、不索取任何证书与 team 信息。

---

## 2. 目录与模块职责

```text
iosApp/
├── project.yml                        # XcodeGen 工程描述（RainCheck + RainCheckTests + ATS + 未签名）
├── ExportOptions.plist                # 带证书导出时的空白模板（已移除废弃 compileBitcode）
├── Resources/
│   ├── Info.plist                     # 含 NSAppTransportSecurity.NSAllowsLocalNetworking = true
│   ├── Assets.xcassets/               # AppIcon（含 Light/Dark/Tinted）与 AccentColor
│   └── protocol_profile.json          # 逐字节同步自 protocol/profile.json
├── Sources/RainCheck/
│   ├── RainCheckApp.swift             # @main 入口
│   ├── RainCheckRootView.swift        # 原生液态玻璃三栏 TabView + 浮动提示条
│   ├── LiquidGlassTheme.swift         # iOS 26/27 Liquid Glass 设计系统 + 多版本兼容护栏 + 极光画布
│   ├── LiquidQRCodeView.swift         # 单例 CIContext + NSCache 缓存 CGImage 二维码视图
│   ├── LiquidScannerSheet.swift       # 串行队列隔离的 AVFoundation 扫码器（防双回调、支持 iPad 旋转）
│   ├── SignStudioView.swift           # 签到台（动态码实时计时、恶意域安全警告、明确勾选流、实时进度环）
│   ├── AccountVaultView.swift         # 账号舱（健康度仪表条、校区着色卡片、双载体状态）
│   ├── ImportAccountSheet.swift       # 安全导入凭据（自动清洗前缀/host、拦截空凭据、失败保留横幅）
│   ├── LiquidLoginSheet.swift         # 受管 .task(id:) 扫码登录（SCANNED / 4 位验证码玻璃框）
│   ├── TelemetryLabView.swift         # 报文实验室（状态筛选胶囊、策略回退时间线、原码失败重试、缓存导出）
│   ├── AppState.swift                 # @MainActor 状态容器（安全回写、无快照覆盖竞态、缓存零凭据导出）
│   ├── AccountVaultStore.swift        # Keychain 凭据存储 + .completeFileProtection + 排除 iCloud 备份
│   ├── Models.swift                   # 100% Sendable 跨端数据模型（SignResult 永久排除 refreshedAccount）
│   ├── ProfileStore.swift             # Bundle 协议加载器 + 路径安全编码模板 + 完整内置兜底协议
│   ├── QrParser.swift                 # 与 QrParser.kt 100% 对齐的二维码解析器（20/20 向量通过）
│   ├── RainCheckApi.swift             # 排除 CFBoolean 陷阱、HTTPCookie 解析、errcode/errmsg 兼容
│   ├── SignInEngine.swift             # 白名单安全拦截、严格零发包 dryRun、可取消 AsyncSemaphore
│   └── LoginService.swift             # pre-info Cookie 透传、SCANNED/NEED_CODE、对齐 Kotlin 降级策略
└── Tests/RainCheckTests/
    ├── TestSupport.swift              # 线程安全 MockURLProtocol 与资源夹具
    ├── QrParserTests.swift            # 加载并断言全部 protocol/vectors/qr_cases.json + 白名单校验
    ├── SignInEngineTests.swift        # 策略回退、恶意域名阻断、ALREADY、DRY_RUN、零凭据导出、Keychain 仓库
    └── LoginServiceTests.swift        # 完整扫码登录、验证码重试、无凭据拦截与降级保留会话
```

---

## 3. 架构说明与同步约束

- **独立 Swift 引擎（与 `core` 契约对齐）**：`iosApp` 不链接 KMP framework，而是以纯 Swift 实现与 Kotlin
  `core` 100% 对齐的协议引擎；所有公共协议定义（7 站点、17 接口、6 策略、8 种 `SignState` 含 `DRY_RUN`、
  `validateQrUrl` 白名单规则）均以 `protocol/profile.json` 为唯一真源。
- **不宣称热更新外部 profile**：iOS 端不从远程或外部文件动态替换协议包，协议更新通过同步
  `protocol/profile.json` → `iosApp/Resources/protocol_profile.json` 后重新构建；CI 会以 `cmp -s`
  强校验两份文件逐字节一致。
- **Swift 严格并发**：`project.yml` 开启 `SWIFT_STRICT_CONCURRENCY: complete`，全部跨 Task 传输模型严格
  `Sendable`，UI 状态隔离在 `@MainActor`，相机采集与硬件手电筒隔离在私有串行 `DispatchQueue`。
