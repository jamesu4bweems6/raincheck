# RainCheck · 雨课堂多账号扫码签到（脱离官方客户端）

一套**不依赖官方 App、全程未签名构建**的多端离线协议研究与演练工具：一次扫描课堂二维码，多账号并发提交签到并保留完整原始报文轨迹。

```text
                ┌───────────── 老师端二维码（静态 / 动态 c/t/s/v）─────────────┐
                │                                                              │
   Android（Jetpack Compose M3 + CameraX/ZXing）        iOS（SwiftUI · iOS 26/27 Liquid Glass）
   CLI（JVM 命令行，支持 --profile 外部协议）           独立原生 Swift 引擎 + Keychain + RainCheckTests
                │                                                              │
       core（KMP: JVM / Android 共享）                          同协议、同向量对齐
                └──────────────► protocol/profile.json ◄───────────────────────┘
                                           │
                        ┌──────────────────┼──────────────────┐
                 Web 短信 / 扫码登录      策略链回退签到         会话自愈回填
             (iOS Web / CLI 桌面推断)   白名单护栏 + DRY_RUN     Set-Auth / Set-Cookie
```

## 1. 核心特性

| 能力 | 说明 |
|---|---|
| 多账号安全仓库 | 支持 `Authorization: Bearer` 与 `sessionid + csrftoken` 双载体；Android 采用 **Keystore AES-GCM** 加密存储，iOS 采用 **Keychain** + 文件保护 + 排除 iCloud 备份，CLI 采用原子落盘与严格文件权限 |
| 全新双端视觉 | Android 采用 **Jetpack Compose Material 3** 极光毛玻璃 + CameraX/ZXing Core 原生扫码；iOS 采用 **SwiftUI iOS 26/27 液态玻璃（Liquid Glass）** 设计系统（`GlassEffectContainer` / `.glassEffect` + 兼容护栏） |
| 并发与策略回退 | 账号间并发（1–32 可调，默认错开 60ms）、账号内串行；按 `DYN_TICKET_14` → `DYN_TICKET_5` → `LESSON_DESKTOP` → `LESSON_WEB` → `QR_URL_POST` → `QR_URL_GET` 回退 |
| 安全防外泄护栏 | `QR_URL_POST` / `QR_URL_GET` 强制 Scheme + Host 白名单，拒绝向任意第三方域外泄凭据或吸收响应头；双端默认关闭扫到即自动提交；导出报告**零明文凭据** |
| 会话自愈 | 响应头 `set-auth` / `Authorization` / `Set-Cookie` 自动回填当前会话与账号池，后续重试与策略即时生效 |
| 报文实验室与零请求演练 | 完整保留每次尝试的请求行、请求体、响应摘要与耗时；`--dry-run` / 演练模式严格零网络请求（输出 `DRY_RUN`） |
| 协议数据化与强一致校验 | 所有端点、模板、策略与关键字收敛在 `protocol/profile.json`；**仅 CLI 支持 `--profile` 热切换外部协议**，移动端通过同步协议副本重新构建并由 CI 强制 SHA-256 校验 |

## 2. 目录结构

```text
work/raincheck/
├─ core/                       Kotlin Multiplatform 协议引擎（Android / JVM 共享；iosMain 未链接至 iosApp）
│  ├─ commonMain               Account、QrParser、RainCheckApi、LoginService、SignInEngine
│  └─ commonTest               基于真实 profile.json 与 qr_cases.json 的单测套件（>= 20 用例）
├─ cli/                        JVM 命令行客户端（parse / accounts / login / signin / context / probe）
├─ androidApp/                 Android 客户端（Jetpack Compose M3 + CameraX + Keystore AES-GCM，未签名 APK）
├─ iosApp/                     iOS 客户端（SwiftUI iOS 26/27 Liquid Glass + 独立 Swift 引擎 + RainCheckTests）
├─ protocol/profile.json       协议单一事实来源（CI 强制与 Android/iOS/CLI 产物逐字节校验）
├─ protocol/vectors/           跨端二维码解析测试向量（qr_cases.json，JVM 与 Swift 单测共用）
├─ tools/mock_server.py        零依赖严格本地演练服务端（双载体鉴权 / source=14 回退 / Web 短信与扫码登录 / 会话刷新）
├─ tools/demo.py               跨平台 6 组全场景端到端验证（8 账号 16 次回退、严格 ALREADY、401、过期、dry-run、登录）
├─ tools/check_artifacts.py    协议同步 / JUnit XML / APK V1+V2+V3 未签名 / iOS YAML 结构化校验工具
├─ tools/verify.ps1            Windows 一键离线全量验收脚本
├─ docs/PROTOCOL.md            协议事实集与 IPA 1.3.6 静态逆向诚实溯源
├─ docs/ARCHITECTURE.md        分层架构、状态机、安全边界与测试体系
└─ docs/BUILD.md               本地与 CI（ubuntu-latest / macos-26）构建指南
```

## 3. 快速开始（离线演练）

```powershell
cd work\raincheck

# 方式一：一键全量离线验收（协议同步 → 强制重跑单测 → CLI → 6 组 E2E 演练 → 未签名 APK → iOS 结构校验）
powershell -NoProfile -File tools\verify.ps1

# 方式二：分步运行协议单测与端到端演练
.\gradlew.bat :core:jvmTest --rerun --console=plain
.\gradlew.bat :cli:installDist --console=plain
python tools\demo.py
```

CLI 常用命令（真实环境使用前请先阅读 [`docs/PROTOCOL.md`](docs/PROTOCOL.md) 风险披露）：

```powershell
$cli = "cli\build\install\cli\bin\cli.bat"

# 推荐通过 stdin 或环境变量 RAINCHECK_TOKEN 导入凭据，避免命令行历史留痕
"<YOUR_TOKEN>" | & $cli accounts import --label 张三 --token-stdin --host www.yuketang.cn

# 或扫码登录（⚠️ 登录轮询链为外部桌面脚本推断，未实网验证）
& $cli login --label 李四 --host pro.yuketang.cn

# 演练模式（零网络请求）或并发签到
& $cli signin --qr "@qr.txt" --concurrency 8 --dry-run
& $cli signin --qr "@qr.txt" --concurrency 8 --json report.json
```

## 4. 构建与 CI（全程未签名）

- **Android（本机 / `ubuntu-latest` CI）**：
  - 构建：`.\gradlew.bat :androidApp:assembleRelease --console=plain`
  - 产物：`androidApp/build/outputs/apk/release/androidApp-release-unsigned.apk`（归档于 `dist/RainCheck-1.0.0-unsigned.apk`）
  - 门禁：同时扫描 **V1（`META-INF/*.RSA/.DSA/.EC/.SF`）** 与 **V2/V3（`APK Sig Block 42`）** 确保真未签名，且验证内嵌 `assets/protocol_profile.json` SHA-256 一致。
  - 工作流：[`.github/workflows/android-unsigned.yml`](.github/workflows/android-unsigned.yml)
- **iOS（macOS / `macos-26` CI，本机 Windows 不编译 IPA）**：
  - 交付源码 + `iosApp/project.yml`（XcodeGen）+ `RainCheckTests` 单元测试靶标。
  - 工作流：[`.github/workflows/ios-unsigned.yml`](.github/workflows/ios-unsigned.yml) 运行于 **`macos-26`**（支持 Xcode 26/27 与 iOS 26/27 Liquid Glass SDK），依次执行 `cmp -s` 协议强校验、Simulator 单元测试、未签名 `.app` 构建、零 `_CodeSignature` 断言并产出 `RainCheck-unsigned.ipa`。
- 完整命令与重签安装步骤见 [`docs/BUILD.md`](docs/BUILD.md) 与 [`dist/README.md`](dist/README.md)。

## 5. 协议溯源与诚实边界

完整证据矩阵与风险披露请务必阅读 [`docs/PROTOCOL.md`](docs/PROTOCOL.md)。要点如下：

- **IPA 1.3.6 静态实证**：核心生产域（`www`/`pro`/`changjiang`/`huanghe.yuketang.cn`、`www.xuetangx.com`，其中荷塘雨课堂对应 `pro.yuketang.cn`）、双载体鉴权、`Set-Auth`/`Set-Cookie`、移动端登录路由（`/api/v3/user/code/send`、`/api/v3/user/login/app`）、`/api/v3/lesson/checkin`、`/api/lesson/web_check_in`、`/wxapi/lesson_check_in`、`/api/v3/app/scan`、`dynamic_qr_error`、`app://yuketang` 等。
- **Web 端协议适配**：统一采用 Web 请求头（`X-Client: web`、`xtbz: ykt`，学堂在线自动切换为 `xt`，动态同源 `Origin`/`Referer`）；iOS 端手机号验证码登录采用 Web PC 端 `/pc/login/send_sms_login_code/` 与 `/pc/login/verify_pwd_login/`（IPA 1.3.6 移动端对应 `/api/v3/user/code/send` + `/api/v3/user/login/app`），且 `authKeywords` 包含 `"登陆"` 与 `"unauthenticated"`。
- **`⚠️ 未实网验证（外部桌面脚本推断）`**：CLI/Android 扫码登录 4 端点轮询链、动态码 `c/t/s/v` 参数语义及 `source=14/5/1` 请求体均在 IPA 中 0 命中，未经实网抓包验证。
- **尚未覆盖 / 未决风险**：第一方 1024-bit RSA 加密字段用途、`wss://<host>/wsapp/` 实时长连接、腾讯/hCaptcha 验证码挑战、静态未验证的运行期 TLS 校验，以及未接入的定位签到接口族。

## 6. 合规声明

- 仅面向自有账号、自有设备与离线本地演练环境；仓库不含任何真实账号、Cookie、Token 或签名证书，也不内置高校私有化子域名。
- 不提供验证码识别、风控对抗或批量注册能力。
- 签到数据属于教学过程数据，多账号代签会与课堂出勤记录冲突，使用前请确认所在学校与课程规定。
